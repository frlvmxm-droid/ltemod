#!/bin/bash
# =============================================================================
# setup-awg-profiles.sh — AmneziaWG obfuscation profile manager
#
# Applies pre-defined Jc/Jmin/Jmax/S1/S2/H1-H4 parameter sets to an
# AmneziaWG config file to adjust obfuscation strength, based on DarkRoute
# research into TSPU fingerprinting resistance.
#
# Profiles:
#   mild       — Jc=2  Jmin=20 Jmax=50  S1=0  S2=0  H1-H4: keep existing
#   moderate   — Jc=4  Jmin=40 Jmax=70  S1=0  S2=0  H1-H4: random
#   aggressive — Jc=7  Jmin=50 Jmax=100 S1=10 S2=10 H1-H4: random
#
# Config vars in /etc/ltemod/ltemod.conf:
#   AMNEZIA_CONFIG="/etc/amnezia/amneziawg/awg0.conf"
#   AMNEZIA_IFACE="awg0"
#
# Usage:
#   setup-awg-profiles.sh apply <profile> [config_path]
#   setup-awg-profiles.sh show  <profile>
#   setup-awg-profiles.sh current [config_path]
#   setup-awg-profiles.sh randomize-headers [config_path]
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

AMNEZIA_CONFIG="${AMNEZIA_CONFIG:-/etc/amnezia/amneziawg/awg0.conf}"
AMNEZIA_IFACE="${AMNEZIA_IFACE:-awg0}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/ltemod}"
PROFILE_STATE_FILE="$RUNTIME_DIR/awg_profile"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    logger -t ltemod-awg-profiles "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
    logger -t ltemod-awg-profiles -p user.err "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# ---------------------------------------------------------------------------
# Random magic header value (based on DarkRoute's randMagicHeader()).
# Generates a random uint32 (never 0).
# ---------------------------------------------------------------------------
rand_header() {
    local val
    val=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    [[ "$val" == "0" ]] && val=1
    echo "$val"
}

# ---------------------------------------------------------------------------
# Profile definitions
# Output format: KEY=VALUE pairs, one per line, for eval-safe parsing.
# H values of "RANDOM" or "KEEP" are resolved by the caller.
# ---------------------------------------------------------------------------
profile_params() {
    local profile="$1"
    case "$profile" in
        mild)
            echo "Jc=2"
            echo "Jmin=20"
            echo "Jmax=50"
            echo "S1=0"
            echo "S2=0"
            echo "H_MODE=keep"
            ;;
        moderate)
            echo "Jc=4"
            echo "Jmin=40"
            echo "Jmax=70"
            echo "S1=0"
            echo "S2=0"
            echo "H_MODE=random"
            ;;
        aggressive)
            echo "Jc=7"
            echo "Jmin=50"
            echo "Jmax=100"
            echo "S1=10"
            echo "S2=10"
            echo "H_MODE=random"
            ;;
        *)
            log_err "Unknown profile: '$profile' — must be mild, moderate, or aggressive"
            exit 1
            ;;
    esac
}

validate_profile() {
    case "${1:-}" in
        mild|moderate|aggressive) return 0 ;;
        *)
            log_err "Unknown profile: '${1:-}' — must be mild, moderate, or aggressive"
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Read a single parameter value from a config file.
# Usage: get_param KEY file
# Returns the value, or empty string if not found.
# ---------------------------------------------------------------------------
get_param() {
    local key="$1" file="$2"
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
        | head -1 \
        | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" \
        | tr -d '\r'
}

# ---------------------------------------------------------------------------
# Set or append a single parameter in the [Interface] section of a config.
# If the key already exists anywhere in the file, it is replaced in-place.
# If it doesn't exist, it is appended right after the [Interface] header line.
# ---------------------------------------------------------------------------
set_param() {
    local key="$1" value="$2" file="$3"

    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null; then
        # Replace existing line (portable sed -i)
        local tmp
        tmp="$(mktemp)"
        sed "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$file" > "$tmp"
        mv "$tmp" "$file"
    else
        # Append after [Interface] header
        if grep -q "^\[Interface\]" "$file" 2>/dev/null; then
            local tmp
            tmp="$(mktemp)"
            awk -v key="$key" -v val="$value" '
                /^\[Interface\]/ {
                    print
                    print key " = " val
                    next
                }
                { print }
            ' "$file" > "$tmp"
            mv "$tmp" "$file"
        else
            # No [Interface] section — just append at end
            echo "${key} = ${value}" >> "$file"
            log_warn() { true; }
            log "Warning: [Interface] section not found in $file — appended $key at end"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Restart the AmneziaWG interface if it is currently up.
# Uses the filename (without .conf extension) as the interface name,
# falling back to AMNEZIA_IFACE.
# ---------------------------------------------------------------------------
maybe_restart_iface() {
    local conf="$1"
    local iface
    iface=$(basename "$conf" .conf)
    # If derived name doesn't look like a valid interface name, fall back
    if [[ -z "$iface" || "$iface" == "$conf" ]]; then
        iface="$AMNEZIA_IFACE"
    fi

    if ip link show "$iface" &>/dev/null 2>&1; then
        log "Interface $iface is up — restarting to apply new config..."
        if command -v awg-quick &>/dev/null; then
            awg-quick down "$conf" 2>/dev/null || \
                ip link delete "$iface" 2>/dev/null || true
            awg-quick up "$conf" && \
                log "Interface $iface restarted successfully" || \
                log_err "awg-quick up failed for $conf"
        else
            log_err "awg-quick not found — cannot restart interface (reboot or restart manually)"
        fi
    else
        log "Interface $iface is not up — config will take effect on next start"
    fi
}

# ---------------------------------------------------------------------------
# Command: apply <profile> [config_path]
# ---------------------------------------------------------------------------
cmd_apply() {
    local profile="${1:-}"
    local conf="${2:-$AMNEZIA_CONFIG}"

    if [[ -z "$profile" ]]; then
        echo "Usage: $0 apply <mild|moderate|aggressive> [config_path]" >&2
        exit 1
    fi
    validate_profile "$profile"

    if [[ ! -f "$conf" ]]; then
        log_err "Config file not found: $conf"
        exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        log_err "Must be run as root"
        exit 1
    fi

    log "=== Applying AWG profile '$profile' to $conf ==="

    # Backup
    cp "$conf" "${conf}.bak"
    log "Backup saved: ${conf}.bak"

    # Parse profile parameters
    local Jc Jmin Jmax S1 S2 H_MODE
    while IFS='=' read -r k v; do
        case "$k" in
            Jc)     Jc="$v"     ;;
            Jmin)   Jmin="$v"   ;;
            Jmax)   Jmax="$v"   ;;
            S1)     S1="$v"     ;;
            S2)     S2="$v"     ;;
            H_MODE) H_MODE="$v" ;;
        esac
    done < <(profile_params "$profile")

    # Apply numeric parameters
    set_param "Jc"   "$Jc"   "$conf"
    set_param "Jmin" "$Jmin" "$conf"
    set_param "Jmax" "$Jmax" "$conf"
    set_param "S1"   "$S1"   "$conf"
    set_param "S2"   "$S2"   "$conf"
    log "Set Jc=$Jc Jmin=$Jmin Jmax=$Jmax S1=$S1 S2=$S2"

    # Apply H1-H4 based on mode
    case "$H_MODE" in
        keep)
            # Mild: preserve existing values; if absent, set to 0
            for h in H1 H2 H3 H4; do
                local existing
                existing=$(get_param "$h" "$conf")
                if [[ -z "$existing" ]]; then
                    set_param "$h" "0" "$conf"
                    log "  $h not found — set to 0"
                else
                    log "  $h kept at $existing"
                fi
            done
            ;;
        random)
            local h1 h2 h3 h4
            h1=$(rand_header)
            h2=$(rand_header)
            h3=$(rand_header)
            h4=$(rand_header)
            set_param "H1" "$h1" "$conf"
            set_param "H2" "$h2" "$conf"
            set_param "H3" "$h3" "$conf"
            set_param "H4" "$h4" "$conf"
            log "  H1=$h1 H2=$h2 H3=$h3 H4=$h4 (randomized)"
            ;;
    esac

    # Save active profile name
    mkdir -p "$RUNTIME_DIR"
    echo "$profile" > "$PROFILE_STATE_FILE"

    log "=== Profile '$profile' applied ==="

    # Restart interface if running
    maybe_restart_iface "$conf"
}

# ---------------------------------------------------------------------------
# Command: show <profile>
# Print the parameters the profile would set (no changes made).
# ---------------------------------------------------------------------------
cmd_show() {
    local profile="${1:-}"
    if [[ -z "$profile" ]]; then
        echo "Usage: $0 show <mild|moderate|aggressive>" >&2
        exit 1
    fi
    validate_profile "$profile"

    echo "Profile: $profile"
    echo ""
    while IFS='=' read -r k v; do
        if [[ "$k" == "H_MODE" ]]; then
            case "$v" in
                keep)   echo "  H1-H4  = (keep existing, or 0 if absent)" ;;
                random) echo "  H1-H4  = (random uint32 each, never 0)"   ;;
            esac
        else
            printf "  %-6s = %s\n" "$k" "$v"
        fi
    done < <(profile_params "$profile")
}

# ---------------------------------------------------------------------------
# Command: current [config_path]
# Show current Jc/Jmin/Jmax/S1/S2/H1-H4 values from the config file.
# ---------------------------------------------------------------------------
cmd_current() {
    local conf="${1:-$AMNEZIA_CONFIG}"

    if [[ ! -f "$conf" ]]; then
        log_err "Config file not found: $conf"
        exit 1
    fi

    echo "=== Current AWG obfuscation parameters ==="
    echo "  Config: $conf"
    echo ""

    local active="(none)"
    [[ -f "$PROFILE_STATE_FILE" ]] && active=$(cat "$PROFILE_STATE_FILE")
    echo "  Active profile: $active"
    echo ""

    for param in Jc Jmin Jmax S1 S2 H1 H2 H3 H4; do
        local val
        val=$(get_param "$param" "$conf")
        if [[ -n "$val" ]]; then
            printf "  %-6s = %s\n" "$param" "$val"
        else
            printf "  %-6s = (not set)\n" "$param"
        fi
    done
}

# ---------------------------------------------------------------------------
# Command: randomize-headers [config_path]
# Randomize H1-H4 without changing junk packet counts.
# Useful for re-fingerprinting resistance between full profile changes.
# ---------------------------------------------------------------------------
cmd_randomize_headers() {
    local conf="${1:-$AMNEZIA_CONFIG}"

    if [[ ! -f "$conf" ]]; then
        log_err "Config file not found: $conf"
        exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        log_err "Must be run as root"
        exit 1
    fi

    log "=== Randomizing H1-H4 in $conf ==="

    # Backup
    cp "$conf" "${conf}.bak"
    log "Backup saved: ${conf}.bak"

    local h1 h2 h3 h4
    h1=$(rand_header)
    h2=$(rand_header)
    h3=$(rand_header)
    h4=$(rand_header)

    set_param "H1" "$h1" "$conf"
    set_param "H2" "$h2" "$conf"
    set_param "H3" "$h3" "$conf"
    set_param "H4" "$h4" "$conf"

    log "H1=$h1 H2=$h2 H3=$h3 H4=$h4"
    log "=== Headers randomized ==="

    maybe_restart_iface "$conf"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
    apply)
        shift
        cmd_apply "${1:-}" "${2:-}"
        ;;
    show)
        shift
        cmd_show "${1:-}"
        ;;
    current)
        shift
        cmd_current "${1:-$AMNEZIA_CONFIG}"
        ;;
    randomize-headers)
        shift
        cmd_randomize_headers "${1:-$AMNEZIA_CONFIG}"
        ;;
    *)
        echo "Usage: $0 {apply <profile> [config]|show <profile>|current [config]|randomize-headers [config]}"
        echo ""
        echo "Profiles: mild | moderate | aggressive"
        exit 1
        ;;
esac
