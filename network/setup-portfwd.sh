#!/bin/bash
# =============================================================================
# setup-portfwd.sh — port forwarding manager (iptables DNAT)
#
# Config file: /etc/ltemod/port-forward.conf
# Format (one rule per non-comment line):
#   name:proto:ext_port:int_ip:int_port
# Example:
#   web:tcp:80:192.168.10.100:80
# Proto: tcp | udp | both
#
# Usage:
#   setup-portfwd.sh apply                              — flush + re-add all rules
#   setup-portfwd.sh flush                              — flush chain only
#   setup-portfwd.sh add name:proto:ext_port:int_ip:int_port
#   setup-portfwd.sh del name                           — remove from config + re-apply
#   setup-portfwd.sh list                               — print rules from config
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

WWAN_IFACE="${WWAN_IFACE:-wwan0}"
PORTFWD_CONF="${PORTFWD_CONF:-/etc/ltemod/port-forward.conf}"
CHAIN="LTEMOD_PORTFWD"

log() {
    logger -t ltemod-portfwd "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
    logger -t ltemod-portfwd -p user.err "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

if [[ $EUID -ne 0 ]]; then
    log_err "Must be run as root"
    exit 1
fi

# ---------------------------------------------------------------------------
# Ensure LTEMOD_PORTFWD chain exists in nat table and is jumped to from
# PREROUTING. Safe to call multiple times.
# ---------------------------------------------------------------------------
ensure_chain() {
    if ! iptables -t nat -L "$CHAIN" -n &>/dev/null; then
        iptables -t nat -N "$CHAIN"
        log "Created chain $CHAIN in nat table"
    fi

    if ! iptables -t nat -C PREROUTING -j "$CHAIN" &>/dev/null 2>&1; then
        iptables -t nat -A PREROUTING -j "$CHAIN"
        log "Added -A PREROUTING -j $CHAIN"
    fi
}

# Flush all rules inside the chain (but keep the chain itself and the
# PREROUTING jump so it stays wired up).
flush_chain() {
    ensure_chain
    iptables -t nat -F "$CHAIN"
    log "Flushed chain $CHAIN"
}

# ---------------------------------------------------------------------------
# Add a single DNAT rule to the chain (already flushed by caller).
# $1 = proto (tcp|udp), $2 = ext_port, $3 = int_ip, $4 = int_port
# ---------------------------------------------------------------------------
add_dnat_rule() {
    local proto="$1" ext_port="$2" int_ip="$3" int_port="$4"
    iptables -t nat -A "$CHAIN" \
        -i "$WWAN_IFACE" \
        -p "$proto" --dport "$ext_port" \
        -j DNAT --to-destination "${int_ip}:${int_port}"
}

# ---------------------------------------------------------------------------
# Parse config and load all rules into the (already flushed) chain.
# ---------------------------------------------------------------------------
load_rules() {
    [[ ! -f "$PORTFWD_CONF" ]] && { log "No config file $PORTFWD_CONF — nothing to load"; return; }

    local count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip blank lines and comments
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]]  && continue

        IFS=':' read -r name proto ext_port int_ip int_port <<< "$line"

        if [[ -z "${name:-}" || -z "${proto:-}" || -z "${ext_port:-}" || \
              -z "${int_ip:-}" || -z "${int_port:-}" ]]; then
            log_err "Skipping malformed line: $line"
            continue
        fi

        case "$proto" in
            tcp|udp)
                add_dnat_rule "$proto" "$ext_port" "$int_ip" "$int_port"
                log "Added rule [$name]: $proto ext=$ext_port -> ${int_ip}:${int_port}"
                count=$((count + 1))
                ;;
            both)
                add_dnat_rule tcp "$ext_port" "$int_ip" "$int_port"
                add_dnat_rule udp "$ext_port" "$int_ip" "$int_port"
                log "Added rule [$name]: tcp+udp ext=$ext_port -> ${int_ip}:${int_port}"
                count=$((count + 2))
                ;;
            *)
                log_err "Unknown proto '$proto' in rule [$name] — skipping"
                ;;
        esac
    done < "$PORTFWD_CONF"

    log "Loaded $count DNAT rules from $PORTFWD_CONF"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_apply() {
    log "=== Applying port-forward rules ==="
    flush_chain
    load_rules
    log "=== Port-forward apply complete ==="
}

cmd_flush() {
    log "=== Flushing port-forward rules ==="
    flush_chain
    log "=== Flush complete ==="
}

cmd_list() {
    if [[ ! -f "$PORTFWD_CONF" ]]; then
        echo "No config file: $PORTFWD_CONF"
        return
    fi
    echo "Port-forward rules ($PORTFWD_CONF):"
    printf "  %-16s %-6s %-10s %-18s %s\n" NAME PROTO EXT_PORT INT_IP INT_PORT
    printf "  %s\n" "--------------------------------------------------------------"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$  ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        IFS=':' read -r name proto ext_port int_ip int_port <<< "$line"
        printf "  %-16s %-6s %-10s %-18s %s\n" "$name" "$proto" "$ext_port" "$int_ip" "$int_port"
    done < "$PORTFWD_CONF"
}

cmd_add() {
    local rule="${1:-}"
    if [[ -z "$rule" ]]; then
        echo "Usage: $0 add name:proto:ext_port:int_ip:int_port" >&2
        exit 1
    fi

    IFS=':' read -r name proto ext_port int_ip int_port <<< "$rule"
    if [[ -z "${name:-}" || -z "${proto:-}" || -z "${ext_port:-}" || \
          -z "${int_ip:-}" || -z "${int_port:-}" ]]; then
        log_err "Malformed rule: $rule"
        exit 1
    fi

    case "$proto" in tcp|udp|both) ;; *)
        log_err "Invalid proto '$proto': must be tcp, udp, or both"
        exit 1
        ;;
    esac

    # Create config file if missing
    mkdir -p "$(dirname "$PORTFWD_CONF")"
    [[ ! -f "$PORTFWD_CONF" ]] && touch "$PORTFWD_CONF"

    # Check for duplicate name
    if grep -qE "^[[:space:]]*${name}:" "$PORTFWD_CONF" 2>/dev/null; then
        log_err "Rule named '$name' already exists — use 'del $name' first"
        exit 1
    fi

    echo "${name}:${proto}:${ext_port}:${int_ip}:${int_port}" >> "$PORTFWD_CONF"
    log "Added rule to config: $rule"

    cmd_apply
}

cmd_del() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Usage: $0 del name" >&2
        exit 1
    fi

    if [[ ! -f "$PORTFWD_CONF" ]]; then
        log_err "Config file not found: $PORTFWD_CONF"
        exit 1
    fi

    if ! grep -qE "^[[:space:]]*${name}:" "$PORTFWD_CONF" 2>/dev/null; then
        log_err "Rule named '$name' not found in config"
        exit 1
    fi

    # Remove lines matching the name (sed in-place, portable)
    local tmp
    tmp="$(mktemp)"
    grep -vE "^[[:space:]]*${name}:" "$PORTFWD_CONF" > "$tmp"
    mv "$tmp" "$PORTFWD_CONF"
    log "Removed rule '$name' from config"

    cmd_apply
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
    apply) cmd_apply ;;
    flush) cmd_flush ;;
    list)  cmd_list  ;;
    add)   shift; cmd_add "${1:-}" ;;
    del)   shift; cmd_del "${1:-}" ;;
    *)
        echo "Usage: $0 {apply|flush|list|add name:proto:ext_port:int_ip:int_port|del name}"
        exit 1
        ;;
esac
