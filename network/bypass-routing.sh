#!/bin/bash
# =============================================================================
# bypass-routing.sh — избирательная маршрутизация (podkop-совместимый обход блокировок)
#
# Реализует два режима:
#   selective — заблокированные домены/IP → VPN, всё остальное → прямой uplink
#   exclude   — VPN для всего, кроме указанных доменов/IP (они → прямой uplink)
#
# Стек:
#   ipset       — хранит IP/подсети bypass-списков
#   iptables mangle PREROUTING MARK — маркирует пакеты для bypass
#   ip rule fwmark → ip route table — направляет помеченный трафик
#   dnsmasq ipset — при резолвинге домена IP попадает в ipset автоматически
#
# Использование:
#   bypass-routing on [selective|exclude] <vpn_iface> <uplink>
#   bypass-routing off
#   bypass-routing status
#   source bypass-routing.sh  (для вызова из vpn-toggle.sh)
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

BYPASS_ENABLED="${BYPASS_ENABLED:-no}"
BYPASS_MODE="${BYPASS_MODE:-selective}"
BYPASS_TABLE="${BYPASS_TABLE:-100}"
BYPASS_FWMARK="${BYPASS_FWMARK:-0x64}"
BYPASS_LIST_PRESET="${BYPASS_LIST_PRESET:-russia-inside}"
BYPASS_LIST_URLS="${BYPASS_LIST_URLS:-}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/ltemod}"
LOG_TAG="${LOG_TAG:-ltemod}"

IPSET_IP="ltemod_bypass_ip"
IPSET_NET="ltemod_bypass_net"
DNSMASQ_BYPASS_CONF="/etc/dnsmasq.d/bypass/bypass.conf"
BYPASS_LIST_DIR="/etc/ltemod/bypass"
LIST_MANAGER="/usr/local/bin/ltemod/list-manager.sh"
[[ ! -f "$LIST_MANAGER" ]] && LIST_MANAGER="$(dirname "$0")/lists/list-manager.sh"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { logger -t "${LOG_TAG}-bypass" "$*" 2>/dev/null || true; echo -e "${CYAN}[bypass]${NC} $*"; }
log_err() { logger -t "${LOG_TAG}-bypass" -p user.err "$*" 2>/dev/null || true; echo -e "${RED}[bypass] ERROR:${NC} $*" >&2; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
info()    { echo -e "  ${YELLOW}→${NC} $*"; }
fail()    { echo -e "  ${RED}✗${NC} $*"; }

# ---------------------------------------------------------------------------
# ipset management
# ---------------------------------------------------------------------------

bypass_ipset_init() {
    if ! command -v ipset &>/dev/null; then
        log_err "ipset not found — install: sudo apt install ipset"
        return 1
    fi
    ipset -! create "$IPSET_IP"  hash:ip  maxelem 1000000 2>/dev/null || true
    ipset -! create "$IPSET_NET" hash:net maxelem 100000  2>/dev/null || true
    ok "ipsets created: $IPSET_IP, $IPSET_NET"
}

bypass_ipset_flush() {
    ipset flush "$IPSET_IP"  2>/dev/null || true
    ipset flush "$IPSET_NET" 2>/dev/null || true
    ok "ipsets flushed"
}

bypass_ipset_destroy() {
    ipset flush   "$IPSET_IP"  2>/dev/null || true
    ipset destroy "$IPSET_IP"  2>/dev/null || true
    ipset flush   "$IPSET_NET" 2>/dev/null || true
    ipset destroy "$IPSET_NET" 2>/dev/null || true
    ok "ipsets removed"
}

# ---------------------------------------------------------------------------
# iptables mangle rules: MARK packets matching bypass sets
# ---------------------------------------------------------------------------

bypass_iptables_add() {
    if ! iptables -t mangle -C PREROUTING -m set --match-set "$IPSET_IP" dst \
            -j MARK --set-mark "$BYPASS_FWMARK" &>/dev/null 2>&1; then
        iptables -t mangle -A PREROUTING -m set --match-set "$IPSET_IP" dst \
            -j MARK --set-mark "$BYPASS_FWMARK"
    fi
    if ! iptables -t mangle -C PREROUTING -m set --match-set "$IPSET_NET" dst \
            -j MARK --set-mark "$BYPASS_FWMARK" &>/dev/null 2>&1; then
        iptables -t mangle -A PREROUTING -m set --match-set "$IPSET_NET" dst \
            -j MARK --set-mark "$BYPASS_FWMARK"
    fi
    # OUTPUT chain: mark locally-generated packets (router's own traffic)
    if ! iptables -t mangle -C OUTPUT -m set --match-set "$IPSET_IP" dst \
            -j MARK --set-mark "$BYPASS_FWMARK" &>/dev/null 2>&1; then
        iptables -t mangle -A OUTPUT -m set --match-set "$IPSET_IP" dst \
            -j MARK --set-mark "$BYPASS_FWMARK"
    fi
    if ! iptables -t mangle -C OUTPUT -m set --match-set "$IPSET_NET" dst \
            -j MARK --set-mark "$BYPASS_FWMARK" &>/dev/null 2>&1; then
        iptables -t mangle -A OUTPUT -m set --match-set "$IPSET_NET" dst \
            -j MARK --set-mark "$BYPASS_FWMARK"
    fi
    ok "iptables mangle MARK rules added (fwmark $BYPASS_FWMARK)"
}

bypass_iptables_del() {
    iptables -t mangle -D PREROUTING -m set --match-set "$IPSET_IP" dst \
        -j MARK --set-mark "$BYPASS_FWMARK" 2>/dev/null || true
    iptables -t mangle -D PREROUTING -m set --match-set "$IPSET_NET" dst \
        -j MARK --set-mark "$BYPASS_FWMARK" 2>/dev/null || true
    iptables -t mangle -D OUTPUT -m set --match-set "$IPSET_IP" dst \
        -j MARK --set-mark "$BYPASS_FWMARK" 2>/dev/null || true
    iptables -t mangle -D OUTPUT -m set --match-set "$IPSET_NET" dst \
        -j MARK --set-mark "$BYPASS_FWMARK" 2>/dev/null || true
    ok "iptables mangle MARK rules removed"
}

# ---------------------------------------------------------------------------
# Policy routing: ip rule fwmark → table; default route in table
# ---------------------------------------------------------------------------

bypass_policy_routes_add() {
    local mode="$1"
    local vpn_iface="$2"
    local uplink="$3"

    # Clean any stale rule for this fwmark
    ip rule del fwmark "$BYPASS_FWMARK" table "$BYPASS_TABLE" 2>/dev/null || true
    ip route flush table "$BYPASS_TABLE" 2>/dev/null || true

    # Add policy rule: packets with our mark → bypass table
    ip rule add fwmark "$BYPASS_FWMARK" table "$BYPASS_TABLE" prio 100

    if [[ "$mode" == "selective" ]]; then
        # selective: bypass-marked packets go through VPN
        ip route add default dev "$vpn_iface" table "$BYPASS_TABLE"
        ok "Policy route: fwmark $BYPASS_FWMARK → $vpn_iface (table $BYPASS_TABLE)"
    else
        # exclude: bypass-marked packets go through uplink (skip VPN)
        local gw
        gw=$(ip route show default dev "$uplink" 2>/dev/null | awk '/via/{print $3}' | head -1 || true)
        if [[ -n "$gw" ]]; then
            ip route add default via "$gw" dev "$uplink" table "$BYPASS_TABLE"
        else
            ip route add default dev "$uplink" table "$BYPASS_TABLE"
        fi
        ok "Policy route: fwmark $BYPASS_FWMARK → $uplink (table $BYPASS_TABLE, direct)"
    fi
}

bypass_policy_routes_del() {
    ip rule del fwmark "$BYPASS_FWMARK" table "$BYPASS_TABLE" 2>/dev/null || true
    ip route flush table "$BYPASS_TABLE" 2>/dev/null || true
    ok "Policy routing rules removed (table $BYPASS_TABLE)"
}

# ---------------------------------------------------------------------------
# FORWARD rules: allow marked traffic through the bypass interface
# ---------------------------------------------------------------------------

bypass_forward_add() {
    local mode="$1"
    local bypass_iface="$2"   # VPN iface in selective, uplink in exclude

    if ! iptables -C FORWARD -m mark --mark "$BYPASS_FWMARK" \
            -o "$bypass_iface" -j ACCEPT &>/dev/null 2>&1; then
        iptables -A FORWARD -m mark --mark "$BYPASS_FWMARK" \
            -o "$bypass_iface" -j ACCEPT
    fi
    # Save bypass iface for teardown
    mkdir -p "$RUNTIME_DIR"
    echo "$bypass_iface" > "$RUNTIME_DIR/bypass_iface"
}

bypass_forward_del() {
    local bypass_iface=""
    [[ -f "$RUNTIME_DIR/bypass_iface" ]] && bypass_iface=$(cat "$RUNTIME_DIR/bypass_iface")
    if [[ -n "$bypass_iface" ]]; then
        iptables -D FORWARD -m mark --mark "$BYPASS_FWMARK" \
            -o "$bypass_iface" -j ACCEPT 2>/dev/null || true
        rm -f "$RUNTIME_DIR/bypass_iface"
    fi
}

# ---------------------------------------------------------------------------
# dnsmasq integration: reload to pick up bypass.conf
# ---------------------------------------------------------------------------

bypass_dnsmasq_reload() {
    if pgrep -x dnsmasq &>/dev/null; then
        pkill -HUP dnsmasq 2>/dev/null || true
        ok "dnsmasq reloaded (bypass.conf active)"
    fi
}

bypass_dnsmasq_clear() {
    if [[ -f "$DNSMASQ_BYPASS_CONF" ]]; then
        rm -f "$DNSMASQ_BYPASS_CONF"
        pkill -HUP dnsmasq 2>/dev/null || true
        ok "dnsmasq bypass.conf removed"
    fi
}

# ---------------------------------------------------------------------------
# Full on/off
# ---------------------------------------------------------------------------

bypass_on() {
    local mode="${1:-$BYPASS_MODE}"
    local vpn_iface="${2:-}"
    local uplink="${3:-}"

    [[ -z "$vpn_iface" ]] && { log_err "bypass_on: vpn_iface required"; return 1; }
    [[ -z "$uplink"    ]] && { log_err "bypass_on: uplink required"; return 1; }

    log "Enabling bypass routing (mode=$mode, vpn=$vpn_iface, uplink=$uplink)"

    bypass_ipset_init || return 1
    bypass_iptables_add
    bypass_policy_routes_add "$mode" "$vpn_iface" "$uplink"

    if [[ "$mode" == "selective" ]]; then
        bypass_forward_add "$mode" "$vpn_iface"
    else
        bypass_forward_add "$mode" "$uplink"
    fi

    # Populate ipsets from existing list files and regenerate dnsmasq conf
    if [[ -f "$LIST_MANAGER" ]]; then
        bash "$LIST_MANAGER" load 2>/dev/null || info "list-manager load: no lists yet (run: list-manager update)"
    fi
    bypass_dnsmasq_reload

    # Save active mode for teardown
    echo "$mode" > "$RUNTIME_DIR/bypass_mode"
    ok "Bypass routing ENABLED (mode=$mode)"
    info "To download lists: sudo list-manager update"
}

bypass_off() {
    log "Disabling bypass routing"

    bypass_iptables_del
    bypass_forward_del
    bypass_policy_routes_del
    bypass_dnsmasq_clear

    # Do NOT destroy ipsets — preserves DNS-populated IPs for fast reconnect
    # bypass_ipset_destroy

    rm -f "$RUNTIME_DIR/bypass_mode"
    ok "Bypass routing DISABLED"
}

bypass_status() {
    echo ""
    echo -e "${CYAN}=== Bypass routing status ===${NC}"

    local mode_file="$RUNTIME_DIR/bypass_mode"
    if [[ -f "$mode_file" ]]; then
        local active_mode; active_mode=$(cat "$mode_file")
        echo -e "  Mode: ${GREEN}${active_mode}${NC} (ACTIVE)"
    else
        echo -e "  Mode: ${YELLOW}INACTIVE${NC}"
    fi

    echo ""
    echo "  [ ipsets ]"
    if command -v ipset &>/dev/null; then
        local cnt_ip cnt_net
        cnt_ip=$(ipset list "$IPSET_IP" 2>/dev/null | grep -c "^[0-9]" || echo 0)
        cnt_net=$(ipset list "$IPSET_NET" 2>/dev/null | grep -c "^[0-9\.]" || echo 0)
        echo -e "    $IPSET_IP:  ${cnt_ip} entries"
        echo -e "    $IPSET_NET: ${cnt_net} entries"
    else
        info "ipset not installed"
    fi

    echo ""
    echo "  [ Policy routing ]"
    ip rule show 2>/dev/null | grep "$BYPASS_FWMARK" | while read -r line; do
        echo "    $line"
    done
    ip route show table "$BYPASS_TABLE" 2>/dev/null | while read -r line; do
        echo "    table $BYPASS_TABLE: $line"
    done

    echo ""
    echo "  [ iptables mangle ]"
    iptables -t mangle -L PREROUTING 2>/dev/null | grep -i "mark\|bypass\|ltemod" | while read -r line; do
        echo "    $line"
    done

    echo ""
    echo "  [ dnsmasq bypass.conf ]"
    if [[ -f "$DNSMASQ_BYPASS_CONF" ]]; then
        local cnt; cnt=$(wc -l < "$DNSMASQ_BYPASS_CONF")
        echo "    $DNSMASQ_BYPASS_CONF: ${cnt} lines"
    else
        echo "    Not present (no domain list loaded)"
    fi

    echo ""
    echo "  [ List files ]"
    if [[ -d "$BYPASS_LIST_DIR" ]]; then
        local found_lists=0
        for f in "$BYPASS_LIST_DIR"/*.lst "$BYPASS_LIST_DIR"/*.conf "$BYPASS_LIST_DIR"/*.custom; do
            [[ -f "$f" ]] || continue
            printf "    %s (%d lines)\n" "$f" "$(wc -l < "$f")"
            found_lists=$((found_lists+1))
        done
        (( found_lists == 0 )) && echo "    <none — run: sudo list-manager update>"
    else
        echo "    $BYPASS_LIST_DIR not found (run: list-manager update)"
    fi
}

# Manually add a single IP to the bypass set
bypass_add_ip() {
    local ip="$1"
    bypass_ipset_init
    ipset add "$IPSET_IP" "$ip" 2>/dev/null || { info "$ip already in set"; return 0; }
    ok "Added $ip to $IPSET_IP"
}

# Manually add a subnet (CIDR) to the bypass net set
bypass_add_net() {
    local cidr="$1"
    bypass_ipset_init
    ipset add "$IPSET_NET" "$cidr" 2>/dev/null || { info "$cidr already in set"; return 0; }
    ok "Added $cidr to $IPSET_NET"
}

# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

# If sourced (by vpn-toggle.sh) — functions are exported, no CLI parsing
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR:${NC} requires root: sudo $0 $*" >&2
    exit 1
fi

CMD="${1:-status}"
shift || true

case "$CMD" in
    on)
        MODE="${1:-$BYPASS_MODE}";       shift || true
        VPNIFACE="${1:-}";               shift || true
        UPLINK="${1:-}";                 shift || true
        bypass_on "$MODE" "$VPNIFACE" "$UPLINK"
        ;;
    off)
        bypass_off
        ;;
    status)
        bypass_status
        ;;
    add-ip)
        [[ -z "${1:-}" ]] && { echo "Usage: $0 add-ip <ip>"; exit 1; }
        bypass_add_ip "$1"
        ;;
    add-net)
        [[ -z "${1:-}" ]] && { echo "Usage: $0 add-net <cidr>"; exit 1; }
        bypass_add_net "$1"
        ;;
    flush)
        bypass_ipset_flush
        bypass_dnsmasq_clear
        ;;
    *)
        echo "Usage: $0 {on [selective|exclude] <vpn_iface> <uplink>|off|status|add-ip <ip>|add-net <cidr>|flush}"
        exit 1
        ;;
esac
