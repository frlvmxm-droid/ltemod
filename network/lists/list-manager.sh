#!/bin/bash
# =============================================================================
# list-manager.sh — управление списками доменов/IP для bypass-routing
#
# Использование:
#   list-manager update [preset|all]  — скачать список(ки) и загрузить в ipset/dnsmasq
#   list-manager load                 — загрузить локальные файлы без скачивания
#   list-manager status               — статус: файлы, размеры, кол-во записей в ipset
#   list-manager flush                — очистить ipset и dnsmasq bypass.conf
#   list-manager add-url <url>        — добавить URL в BYPASS_LIST_URLS в конфиге
#
# Форматы списков:
#   dnsmasq-ipset: ipset=/domain.com/set_name  (автоматически детектируется)
#   raw IP/CIDR:   по одному на строку (автоматически детектируется)
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

BYPASS_ENABLED="${BYPASS_ENABLED:-no}"
BYPASS_LIST_PRESET="${BYPASS_LIST_PRESET:-russia-inside}"
BYPASS_LIST_URLS="${BYPASS_LIST_URLS:-}"
BYPASS_LIST_DIR="${BYPASS_LIST_DIR:-/etc/ltemod/bypass}"
LOG_TAG="${LOG_TAG:-ltemod}"

IPSET_IP="ltemod_bypass_ip"
IPSET_NET="ltemod_bypass_net"
DNSMASQ_BYPASS_DIR="/etc/dnsmasq.d/bypass"
DNSMASQ_BYPASS_CONF="$DNSMASQ_BYPASS_DIR/bypass.conf"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
info() { echo -e "  ${YELLOW}→${NC} $*"; }
log()  { logger -t "${LOG_TAG}-lists" "$*" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Built-in preset URLs (itdoginfo/allow-domains)
# ---------------------------------------------------------------------------
BASE_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main"

declare -A PRESET_URLS=(
    [russia-inside-domains]="${BASE_URL}/Russia/inside-dnsmasq-ipset.lst"
    [russia-inside-ip]="${BASE_URL}/Russia/inside-ip.lst"
    [russia-outside-domains]="${BASE_URL}/Russia/outside-dnsmasq-ipset.lst"
    [russia-outside-ip]="${BASE_URL}/Russia/outside-ip.lst"
)

# Preset → which sub-presets to download
declare -A PRESET_GROUPS=(
    [russia-inside]="russia-inside-domains russia-inside-ip"
    [russia-outside]="russia-outside-domains russia-outside-ip"
    [all]="russia-inside-domains russia-inside-ip russia-outside-domains russia-outside-ip"
    [none]=""
)

# ---------------------------------------------------------------------------
# Detect list format: "dnsmasq-ipset" | "raw-ip"
# ---------------------------------------------------------------------------
detect_format() {
    local file="$1"
    # Sample first non-empty, non-comment line
    local sample
    sample=$(grep -v '^#' "$file" 2>/dev/null | grep -v '^[[:space:]]*$' | head -5 || true)
    if echo "$sample" | grep -q '^ipset=/'; then
        echo "dnsmasq-ipset"
    else
        echo "raw-ip"
    fi
}

# ---------------------------------------------------------------------------
# Download a single URL → local file
# ---------------------------------------------------------------------------
download_url() {
    local url="$1"
    local dest="$2"

    local tmpfile="${dest}.tmp"
    info "Downloading: $(basename "$dest")..."

    if command -v wget &>/dev/null; then
        wget -q -O "$tmpfile" "$url" 2>&1 || { fail "wget failed: $url"; return 1; }
    elif command -v curl &>/dev/null; then
        curl -fsSL -o "$tmpfile" "$url" 2>&1 || { fail "curl failed: $url"; return 1; }
    else
        fail "Neither wget nor curl found — cannot download lists"
        return 1
    fi

    # Basic sanity check
    local lines
    lines=$(wc -l < "$tmpfile" 2>/dev/null || echo 0)
    if (( lines < 5 )); then
        fail "Downloaded file too small (${lines} lines) — skipping: $url"
        rm -f "$tmpfile"
        return 1
    fi

    mv "$tmpfile" "$dest"
    ok "Saved: $dest (${lines} lines)"
    log "Downloaded $url → $dest (${lines} lines)"
}

# ---------------------------------------------------------------------------
# Load a single list file into ipset / generate dnsmasq conf lines
# ---------------------------------------------------------------------------
load_file() {
    local file="$1"
    local dnsmasq_lines_ref="$2"   # name of array to append dnsmasq lines to

    [[ ! -f "$file" ]] && return 0

    local fmt; fmt=$(detect_format "$file")

    if [[ "$fmt" == "dnsmasq-ipset" ]]; then
        # Rewrite set name to ltemod_bypass_ip and collect for dnsmasq conf
        while IFS= read -r line; do
            [[ "$line" =~ ^#   ]] && continue
            [[ -z "$line"       ]] && continue
            # Replace any set name after last / with our set name
            local new_line
            new_line=$(echo "$line" | sed 's|/[^/]*$|/'"$IPSET_IP"'|')
            eval "${dnsmasq_lines_ref}+=(\"\$new_line\")"
        done < "$file"
    else
        # Raw IP/CIDR: load into ipset
        if ! command -v ipset &>/dev/null; then
            fail "ipset not found — cannot load IP/CIDR list: $file"
            return 0
        fi
        local added=0
        local skipped=0
        while IFS= read -r line; do
            [[ "$line" =~ ^# ]] && continue
            [[ -z "$line"     ]] && continue
            # Accept IPv4, IPv4/CIDR
            if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                if [[ "$line" =~ / ]]; then
                    ipset -! add "$IPSET_NET" "$line" 2>/dev/null && added=$((added+1)) || skipped=$((skipped+1))
                else
                    ipset -! add "$IPSET_IP"  "$line" 2>/dev/null && added=$((added+1)) || skipped=$((skipped+1))
                fi
            fi
        done < "$file"
        info "  IP list $(basename "$file"): +${added} entries (${skipped} duplicates)"
    fi
}

# ---------------------------------------------------------------------------
# Load all list files → populate ipset + write dnsmasq bypass.conf
# ---------------------------------------------------------------------------
cmd_load() {
    if ! command -v ipset &>/dev/null; then
        fail "ipset not found — install: sudo apt install ipset"
        exit 1
    fi

    # Ensure ipsets exist
    ipset -! create "$IPSET_IP"  hash:ip  maxelem 1000000 2>/dev/null || true
    ipset -! create "$IPSET_NET" hash:net maxelem 100000  2>/dev/null || true

    mkdir -p "$DNSMASQ_BYPASS_DIR"

    local -a dnsmasq_lines=()
    local loaded=0

    for f in "$BYPASS_LIST_DIR"/*.lst "$BYPASS_LIST_DIR"/*.conf "$BYPASS_LIST_DIR"/*.custom; do
        [[ -f "$f" ]] || continue
        info "Loading: $f"
        load_file "$f" dnsmasq_lines
        loaded=$((loaded+1))
    done

    if (( loaded == 0 )); then
        info "No list files found in $BYPASS_LIST_DIR"
        info "Run: sudo list-manager update"
        return 0
    fi

    # Write dnsmasq bypass.conf
    if (( ${#dnsmasq_lines[@]} > 0 )); then
        {
            echo "# ltemod bypass domain → ipset mapping"
            echo "# Generated by list-manager — do not edit manually"
            printf '%s\n' "${dnsmasq_lines[@]}"
        } > "$DNSMASQ_BYPASS_CONF"
        ok "dnsmasq bypass.conf: ${#dnsmasq_lines[@]} domain entries → $DNSMASQ_BYPASS_CONF"

        # Reload dnsmasq if running
        if pgrep -x dnsmasq &>/dev/null; then
            pkill -HUP dnsmasq 2>/dev/null || true
            ok "dnsmasq reloaded"
        fi
    fi

    local ip_cnt net_cnt
    ip_cnt=$(ipset list  "$IPSET_IP"  2>/dev/null | grep -c '^[0-9]' || echo 0)
    net_cnt=$(ipset list "$IPSET_NET" 2>/dev/null | grep -c '^[0-9\.]' || echo 0)
    ok "ipsets: $IPSET_IP=${ip_cnt} IPs, $IPSET_NET=${net_cnt} subnets"
    log "Lists loaded: domains=${#dnsmasq_lines[@]}, IPs=${ip_cnt}, nets=${net_cnt}"
}

# ---------------------------------------------------------------------------
# Download preset(s) and/or custom URLs
# ---------------------------------------------------------------------------
cmd_update() {
    local target="${1:-${BYPASS_LIST_PRESET:-russia-inside}}"

    mkdir -p "$BYPASS_LIST_DIR"

    local presets_to_download=""

    # Resolve preset group
    if [[ -n "${PRESET_GROUPS[$target]+_}" ]]; then
        presets_to_download="${PRESET_GROUPS[$target]}"
    else
        # Maybe a specific sub-preset was requested
        if [[ -n "${PRESET_URLS[$target]+_}" ]]; then
            presets_to_download="$target"
        else
            fail "Unknown preset: $target"
            echo ""
            echo "Available presets: russia-inside | russia-outside | all | none"
            echo "Sub-presets: ${!PRESET_URLS[*]}"
            exit 1
        fi
    fi

    local ok_count=0

    # Download preset files
    for preset in $presets_to_download; do
        local url="${PRESET_URLS[$preset]}"
        local dest="$BYPASS_LIST_DIR/${preset}.lst"
        download_url "$url" "$dest" && ok_count=$((ok_count+1)) || true
    done

    # Download custom URLs
    if [[ -n "$BYPASS_LIST_URLS" ]]; then
        local idx=0
        for url in $BYPASS_LIST_URLS; do
            local dest="$BYPASS_LIST_DIR/custom-${idx}.custom"
            download_url "$url" "$dest" && ok_count=$((ok_count+1)) || true
            idx=$((idx+1))
        done
    fi

    if (( ok_count == 0 )); then
        fail "No lists downloaded"
        exit 1
    fi

    ok "Downloaded $ok_count list file(s)"
    echo ""

    # Immediately load into ipset / dnsmasq
    cmd_load
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
cmd_status() {
    echo -e "${CYAN}=== list-manager status ===${NC}"

    echo ""
    echo "  [ Config ]"
    echo "    BYPASS_ENABLED:    $BYPASS_ENABLED"
    echo "    BYPASS_LIST_PRESET: $BYPASS_LIST_PRESET"
    echo "    BYPASS_LIST_URLS:  ${BYPASS_LIST_URLS:-<none>}"
    echo "    List dir:          $BYPASS_LIST_DIR"

    echo ""
    echo "  [ Downloaded lists ]"
    if [[ -d "$BYPASS_LIST_DIR" ]]; then
        local found=0
        for f in "$BYPASS_LIST_DIR"/*.lst "$BYPASS_LIST_DIR"/*.conf "$BYPASS_LIST_DIR"/*.custom; do
            [[ -f "$f" ]] || continue
            local lines; lines=$(wc -l < "$f")
            local mtime; mtime=$(stat -c '%y' "$f" 2>/dev/null | cut -d. -f1 || echo "unknown")
            printf "    %-40s %6d lines  %s\n" "$(basename "$f")" "$lines" "$mtime"
            found=$((found+1))
        done
        (( found == 0 )) && echo "    <none — run: sudo list-manager update>"
    else
        echo "    Directory not found: $BYPASS_LIST_DIR"
    fi

    echo ""
    echo "  [ ipsets ]"
    if command -v ipset &>/dev/null; then
        for setname in "$IPSET_IP" "$IPSET_NET"; do
            if ipset list "$setname" &>/dev/null 2>&1; then
                local cnt; cnt=$(ipset list "$setname" 2>/dev/null | grep -c '^[0-9]' || echo 0)
                echo "    $setname: $cnt entries"
            else
                echo "    $setname: not created"
            fi
        done
    else
        echo "    ipset not installed"
    fi

    echo ""
    echo "  [ dnsmasq bypass.conf ]"
    if [[ -f "$DNSMASQ_BYPASS_CONF" ]]; then
        local cnt; cnt=$(wc -l < "$DNSMASQ_BYPASS_CONF")
        echo "    $DNSMASQ_BYPASS_CONF: ${cnt} lines"
    else
        echo "    Not present"
    fi
}

# ---------------------------------------------------------------------------
# Flush ipsets and dnsmasq bypass.conf
# ---------------------------------------------------------------------------
cmd_flush() {
    if command -v ipset &>/dev/null; then
        ipset flush "$IPSET_IP"  2>/dev/null || true
        ipset flush "$IPSET_NET" 2>/dev/null || true
        ok "ipsets flushed"
    fi
    if [[ -f "$DNSMASQ_BYPASS_CONF" ]]; then
        rm -f "$DNSMASQ_BYPASS_CONF"
        pkill -HUP dnsmasq 2>/dev/null || true
        ok "dnsmasq bypass.conf removed"
    fi
}

# ---------------------------------------------------------------------------
# Add custom URL to config
# ---------------------------------------------------------------------------
cmd_add_url() {
    local url="${1:-}"
    [[ -z "$url" ]] && { echo "Usage: $0 add-url <url>"; exit 1; }

    if grep -q 'BYPASS_LIST_URLS=' "$CONFIG_FILE" 2>/dev/null; then
        local current; current=$(grep '^BYPASS_LIST_URLS=' "$CONFIG_FILE" | cut -d= -f2- | tr -d '"')
        if [[ -z "$current" ]]; then
            sed -i "s|^BYPASS_LIST_URLS=.*|BYPASS_LIST_URLS=\"$url\"|" "$CONFIG_FILE"
        else
            sed -i "s|^BYPASS_LIST_URLS=.*|BYPASS_LIST_URLS=\"$current $url\"|" "$CONFIG_FILE"
        fi
        ok "Added URL to BYPASS_LIST_URLS in $CONFIG_FILE"
        info "URL: $url"
    else
        fail "BYPASS_LIST_URLS not found in $CONFIG_FILE"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
CMD="${1:-status}"
shift || true

case "$CMD" in
    update)  cmd_update "${1:-}" ;;
    load)    cmd_load ;;
    status)  cmd_status ;;
    flush)   cmd_flush ;;
    add-url) cmd_add_url "${1:-}" ;;
    *)
        echo "Usage: $0 {update [preset]|load|status|flush|add-url <url>}"
        echo ""
        echo "Presets: russia-inside | russia-outside | all | none"
        exit 1
        ;;
esac
