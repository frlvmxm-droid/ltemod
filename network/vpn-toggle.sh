#!/bin/bash
# =============================================================================
# vpn-toggle.sh — переключение VPN протоколов
#
# Использование:
#   vpn-toggle [wg|amnezia|vless] on    — включить указанный VPN
#   vpn-toggle [wg|amnezia|vless] off   — выключить (вернуть прямой uplink)
#   vpn-toggle status                   — статус всех протоколов
#   vpn-toggle off                      — выключить любой активный VPN
#
# Протоколы:
#   wg      — WireGuard (wg-quick)
#   amnezia — AmneziaWG (awg-quick, обфусцированный WireGuard)
#   vless   — VLESS через sing-box (TUN режим)
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

WWAN_IFACE="${WWAN_IFACE:-wwan0}"
LAN_IFACE="${LAN_IFACE:-end0}"
WIFI_AP_IFACE="${WIFI_AP_IFACE:-wlan0}"
WIFI_AP_ENABLED="${WIFI_AP_ENABLED:-yes}"
VPN_KILLSWITCH="${VPN_KILLSWITCH:-no}"
VPN_IFACE="${VPN_IFACE:-wg0}"
WG_CONFIG="${WG_CONFIG:-/etc/wireguard/wg0.conf}"
AMNEZIA_IFACE="${AMNEZIA_IFACE:-awg0}"
AMNEZIA_CONFIG="${AMNEZIA_CONFIG:-/etc/amnezia/amneziawg/awg0.conf}"
VLESS_CONFIG="${VLESS_CONFIG:-/etc/sing-box/config.json}"
VLESS_TUN_IFACE="${VLESS_TUN_IFACE:-tun0}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/ltemod}"
MODE_FILE="${MODE_FILE:-/run/ltemod/mode}"
LOG_TAG="${LOG_TAG:-ltemod}"
BYPASS_ENABLED="${BYPASS_ENABLED:-no}"
BYPASS_MODE="${BYPASS_MODE:-selective}"

BYPASS_SH="/usr/local/bin/ltemod/bypass-routing.sh"
[[ -f "$BYPASS_SH" ]] || BYPASS_SH="$(dirname "$0")/bypass-routing.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { logger -t "${LOG_TAG}-vpn" "$*"; echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
log_err() { logger -t "${LOG_TAG}-vpn" -p user.err "$*"; echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
fail()    { echo -e "  ${RED}✗${NC} $*"; }
info()    { echo -e "  ${YELLOW}→${NC} $*"; }

get_mode() { [[ -f "$MODE_FILE" ]] && cat "$MODE_FILE" || echo "direct"; }

# Путь к kill-switch скрипту (симлинк или рядом)
KILLSWITCH_SH="/usr/local/bin/killswitch"
[[ -f "$KILLSWITCH_SH" ]] || KILLSWITCH_SH="$(dirname "$0")/killswitch.sh"

# Включить kill-switch (если VPN_KILLSWITCH=yes): блокировать трафик клиентов
# мимо VPN-интерфейса + перехват DNS.
killswitch_enable() {
    local vpn_iface="$1"
    [[ "$VPN_KILLSWITCH" == "yes" ]] || return 0
    [[ -f "$KILLSWITCH_SH" ]] || { info "killswitch.sh not found — skipping"; return 0; }
    local uplink; uplink=$(get_uplink_iface)
    bash "$KILLSWITCH_SH" on "$vpn_iface" "$uplink" && ok "Kill-switch enabled ($vpn_iface)" || true
}

# Выключить kill-switch (всегда безопасно вызывать)
killswitch_disable() {
    [[ -f "$KILLSWITCH_SH" ]] || return 0
    bash "$KILLSWITCH_SH" off &>/dev/null || true
}

# Получить текущий uplink интерфейс
get_uplink_iface() {
    local uplink_file="$RUNTIME_DIR/uplink_iface"
    if [[ -f "$uplink_file" ]]; then
        cat "$uplink_file"
    else
        echo "$WWAN_IFACE"
    fi
}

# ---------------------------------------------------------------------------
# Общая логика: добавить default route через VPN интерфейс
# ---------------------------------------------------------------------------
setup_vpn_routes() {
    local vpn_iface="$1"
    local uplink
    uplink=$(get_uplink_iface)

    # Получить endpoint сервера (для WG/AmneziaWG)
    local endpoint=""
    if command -v wg &>/dev/null && ip link show "$vpn_iface" &>/dev/null; then
        endpoint=$(wg show "$vpn_iface" endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1 | head -1 || true)
    fi
    if command -v awg &>/dev/null && ip link show "$vpn_iface" &>/dev/null; then
        endpoint=$(awg show "$vpn_iface" endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1 | head -1 || true)
    fi

    # Защитный маршрут к endpoint через uplink (не допустить петли)
    if [[ -n "$endpoint" ]]; then
        local gw
        gw=$(ip route show default dev "$uplink" 2>/dev/null | awk '/via/ {print $3}' | head -1 || true)
        if [[ -n "$gw" ]]; then
            ip route replace "$endpoint/32" via "$gw" dev "$uplink" 2>/dev/null || true
            log "Endpoint route: $endpoint via $gw ($uplink)"
            # Сохранить endpoint, чтобы restore_direct() мог удалить этот маршрут
            mkdir -p "$RUNTIME_DIR"
            echo "$endpoint" > "$RUNTIME_DIR/vpn_endpoint"
        fi
    fi

    # В selective-режиме bypass-routing.sh управляет таблицей маршрутов сам:
    # VPN — только для помеченного трафика, основной маршрут остаётся через uplink.
    if [[ "$BYPASS_ENABLED" == "yes" && "$BYPASS_MODE" == "selective" ]]; then
        log "Bypass selective mode: skipping full-tunnel default route"
        # Удалить дефолтный маршрут, который wg-quick/awg-quick мог добавить сам
        ip route del default dev "$vpn_iface" 2>/dev/null || true
        # Настроить selective bypass (ipset + policy routing)
        if [[ -f "$BYPASS_SH" ]]; then
            bash "$BYPASS_SH" on selective "$vpn_iface" "$uplink"
        fi
        return 0
    fi

    # Сохранить текущий uplink route как резервный (metric 200)
    if ip route show default dev "$uplink" &>/dev/null 2>&1; then
        ip route del default dev "$uplink" 2>/dev/null || true
        ip route add default dev "$uplink" metric 200 2>/dev/null || true
        log "Uplink $uplink moved to metric 200 (backup)"
    fi

    # Добавить default route через VPN (metric 100)
    ip route add default dev "$vpn_iface" metric 100 2>/dev/null || \
    ip route replace default dev "$vpn_iface" metric 100
    ok "Default route: $vpn_iface (metric 100)"

    # В exclude-режиме bypass-routing.sh добавляет исключения (→ прямой uplink)
    if [[ "$BYPASS_ENABLED" == "yes" && "$BYPASS_MODE" == "exclude" ]]; then
        if [[ -f "$BYPASS_SH" ]]; then
            bash "$BYPASS_SH" on exclude "$vpn_iface" "$uplink"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Общая логика: переключить iptables на VPN интерфейс
# ---------------------------------------------------------------------------
setup_vpn_iptables() {
    local vpn_iface="$1"
    local uplink
    uplink=$(get_uplink_iface)

    # Убрать MASQUERADE с uplink и WiFi AP сети
    iptables -t nat -D POSTROUTING -o "$uplink" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "$vpn_iface" -j MASQUERADE 2>/dev/null || true
    # Добавить MASQUERADE на VPN
    iptables -t nat -A POSTROUTING -o "$vpn_iface" -j MASQUERADE
    ok "MASQUERADE: $vpn_iface"

    # FORWARD: LAN → VPN
    iptables -D FORWARD -i "$LAN_IFACE" -o "$uplink" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$uplink" -o "$LAN_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    if ! iptables -C FORWARD -i "$LAN_IFACE" -o "$vpn_iface" -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -i "$LAN_IFACE" -o "$vpn_iface" -j ACCEPT
    fi
    if ! iptables -C FORWARD -i "$vpn_iface" -o "$LAN_IFACE" \
            -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -i "$vpn_iface" -o "$LAN_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi

    # FORWARD: WiFi AP → VPN
    if [[ "$WIFI_AP_ENABLED" == "yes" ]]; then
        iptables -D FORWARD -i "$WIFI_AP_IFACE" -o "$uplink" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i "$uplink" -o "$WIFI_AP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

        if ! iptables -C FORWARD -i "$WIFI_AP_IFACE" -o "$vpn_iface" -j ACCEPT &>/dev/null 2>&1; then
            iptables -A FORWARD -i "$WIFI_AP_IFACE" -o "$vpn_iface" -j ACCEPT
        fi
        if ! iptables -C FORWARD -i "$vpn_iface" -o "$WIFI_AP_IFACE" \
                -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null 2>&1; then
            iptables -A FORWARD -i "$vpn_iface" -o "$WIFI_AP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
        fi
    fi

    ok "FORWARD rules: LAN+WiFi → $vpn_iface"

    # Kill-switch: запретить любой выход клиентов мимо VPN
    killswitch_enable "$vpn_iface"
}

# ---------------------------------------------------------------------------
# Общая логика: восстановить прямой uplink (выключить VPN)
# ---------------------------------------------------------------------------
restore_direct() {
    local vpn_iface="$1"
    local uplink
    uplink=$(get_uplink_iface)

    # Снять kill-switch ДО восстановления прямого форвардинга (убрать DROP/DNS)
    killswitch_disable

    # Убрать default route через VPN
    ip route del default dev "$vpn_iface" metric 100 2>/dev/null || true
    ip route del default dev "$vpn_iface" 2>/dev/null || true

    # Восстановить uplink как основной
    if ip link show "$uplink" &>/dev/null; then
        ip route del default dev "$uplink" metric 200 2>/dev/null || true
        ip route add default dev "$uplink" metric 100 2>/dev/null || true
        ok "Default route restored: $uplink"
    fi

    # Убрать защитный endpoint маршрут (endpoint/32 via gw dev uplink)
    if [[ -f "$RUNTIME_DIR/vpn_endpoint" ]]; then
        local endpoint
        endpoint=$(cat "$RUNTIME_DIR/vpn_endpoint")
        if [[ -n "$endpoint" ]]; then
            ip route del "$endpoint/32" 2>/dev/null || true
            log "Removed endpoint route: $endpoint"
        fi
        rm -f "$RUNTIME_DIR/vpn_endpoint"
    fi

    # Восстановить iptables
    iptables -t nat -D POSTROUTING -o "$vpn_iface" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "$uplink" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$uplink" -j MASQUERADE
    ok "MASQUERADE restored: $uplink"

    # FORWARD: убрать VPN, вернуть uplink
    iptables -D FORWARD -i "$LAN_IFACE" -o "$vpn_iface" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$vpn_iface" -o "$LAN_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$WIFI_AP_IFACE" -o "$vpn_iface" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$vpn_iface" -o "$WIFI_AP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    if ! iptables -C FORWARD -i "$LAN_IFACE" -o "$uplink" -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -i "$LAN_IFACE" -o "$uplink" -j ACCEPT
    fi
    if ! iptables -C FORWARD -i "$uplink" -o "$LAN_IFACE" \
            -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -i "$uplink" -o "$LAN_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi

    if [[ "$WIFI_AP_ENABLED" == "yes" ]]; then
        if ! iptables -C FORWARD -i "$WIFI_AP_IFACE" -o "$uplink" -j ACCEPT &>/dev/null 2>&1; then
            iptables -A FORWARD -i "$WIFI_AP_IFACE" -o "$uplink" -j ACCEPT
        fi
        if ! iptables -C FORWARD -i "$uplink" -o "$WIFI_AP_IFACE" \
                -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null 2>&1; then
            iptables -A FORWARD -i "$uplink" -o "$WIFI_AP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
        fi
    fi

    ok "FORWARD rules restored: direct $uplink"

    # Снять bypass routing (ipset marks, policy rules, dnsmasq bypass.conf)
    if [[ "$BYPASS_ENABLED" == "yes" && -f "$BYPASS_SH" ]]; then
        bash "$BYPASS_SH" off 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Гарантировать, что активен только один VPN: если включён другой протокол —
# корректно выключить его (с очисткой маршрутов и iptables) перед стартом нового.
# ---------------------------------------------------------------------------
ensure_single_vpn() {
    local target="$1"
    local cur
    cur=$(get_mode)
    [[ "$cur" == "$target" ]] && return 0
    case "$cur" in
        wg)      info "Switching from WireGuard → $target"; wg_off ;;
        amnezia) info "Switching from AmneziaWG → $target"; amnezia_off ;;
        vless)   info "Switching from VLESS → $target";     vless_off ;;
    esac
}

# =============================================================================
# WireGuard
# =============================================================================
wg_on() {
    log "Enabling WireGuard VPN..."
    ensure_single_vpn "wg"

    if [[ ! -f "$WG_CONFIG" ]]; then
        log_err "WireGuard config not found: $WG_CONFIG"
        log_err "Run: sudo setup-vpn /path/to/wg0.conf"
        exit 1
    fi

    # Записать режим ДО старта — watchdog сможет повторить попытку если VPN упадёт
    mkdir -p "$RUNTIME_DIR"
    echo "wg" > "$MODE_FILE"

    if ! ip link show "$VPN_IFACE" &>/dev/null; then
        wg-quick up "$VPN_IFACE" || { log_err "Failed to start WireGuard"; exit 1; }
        ok "WireGuard $VPN_IFACE started"
    else
        info "WireGuard $VPN_IFACE already up"
    fi

    setup_vpn_routes "$VPN_IFACE"
    setup_vpn_iptables "$VPN_IFACE"
    echo ""
    ok "WireGuard VPN ENABLED"
    echo -e "  Traffic: ${CYAN}LAN/WiFi → WireGuard ($VPN_IFACE) → Internet${NC}"
    log "Mode: wg"
}

wg_off() {
    log "Disabling WireGuard VPN..."
    restore_direct "$VPN_IFACE"

    if ip link show "$VPN_IFACE" &>/dev/null; then
        wg-quick down "$VPN_IFACE" || ip link delete "$VPN_IFACE" 2>/dev/null || true
        ok "WireGuard $VPN_IFACE stopped"
    fi

    mkdir -p "$RUNTIME_DIR"
    echo "direct" > "$MODE_FILE"
    echo ""
    ok "Direct uplink ENABLED (WireGuard off)"
    log "Mode: direct"
}

# =============================================================================
# AmneziaWG
# =============================================================================
amnezia_on() {
    log "Enabling AmneziaWG VPN..."
    ensure_single_vpn "amnezia"

    if ! command -v awg-quick &>/dev/null; then
        log_err "awg-quick not found. Install AmneziaWG first (see install.sh)"
        exit 1
    fi

    if [[ ! -f "$AMNEZIA_CONFIG" ]]; then
        log_err "AmneziaWG config not found: $AMNEZIA_CONFIG"
        log_err "Run: sudo setup-amnezia /path/to/awg0.conf"
        exit 1
    fi

    mkdir -p "$RUNTIME_DIR"
    echo "amnezia" > "$MODE_FILE"

    if ! ip link show "$AMNEZIA_IFACE" &>/dev/null; then
        awg-quick up "$AMNEZIA_CONFIG" || { log_err "Failed to start AmneziaWG"; exit 1; }
        ok "AmneziaWG $AMNEZIA_IFACE started"
    else
        info "AmneziaWG $AMNEZIA_IFACE already up"
    fi

    setup_vpn_routes "$AMNEZIA_IFACE"
    setup_vpn_iptables "$AMNEZIA_IFACE"
    echo ""
    ok "AmneziaWG VPN ENABLED"
    echo -e "  Traffic: ${CYAN}LAN/WiFi → AmneziaWG ($AMNEZIA_IFACE) → Internet${NC}"
    log "Mode: amnezia"
}

amnezia_off() {
    log "Disabling AmneziaWG VPN..."
    restore_direct "$AMNEZIA_IFACE"

    if ip link show "$AMNEZIA_IFACE" &>/dev/null; then
        awg-quick down "$AMNEZIA_CONFIG" 2>/dev/null || \
        ip link delete "$AMNEZIA_IFACE" 2>/dev/null || true
        ok "AmneziaWG $AMNEZIA_IFACE stopped"
    fi

    mkdir -p "$RUNTIME_DIR"
    echo "direct" > "$MODE_FILE"
    echo ""
    ok "Direct uplink ENABLED (AmneziaWG off)"
    log "Mode: direct"
}

# =============================================================================
# VLESS (sing-box)
# =============================================================================
vless_on() {
    log "Enabling VLESS (sing-box)..."
    ensure_single_vpn "vless"

    if ! command -v sing-box &>/dev/null; then
        log_err "sing-box not found. Run: sudo bash install.sh"
        exit 1
    fi

    if [[ ! -f "$VLESS_CONFIG" ]]; then
        log_err "VLESS config not found: $VLESS_CONFIG"
        log_err "Run: sudo setup-vless /path/to/config.json"
        exit 1
    fi

    # sing-box управляет маршрутизацией через auto_route=true в конфиге
    # Нам нужно лишь запустить сервис и убедиться что TUN создался

    # Остановить конкурирующие VPN
    if ip link show "$VPN_IFACE" &>/dev/null; then
        wg-quick down "$VPN_IFACE" 2>/dev/null || true
    fi
    if ip link show "$AMNEZIA_IFACE" &>/dev/null; then
        awg-quick down "$AMNEZIA_CONFIG" 2>/dev/null || true
    fi

    local uplink
    uplink=$(get_uplink_iface)

    mkdir -p "$RUNTIME_DIR"
    echo "vless" > "$MODE_FILE"

    systemctl start sing-box || { log_err "Failed to start sing-box service"; exit 1; }
    ok "sing-box service started"

    # Подождать создания TUN интерфейса
    local timeout=15
    local elapsed=0
    while ! ip link show "$VLESS_TUN_IFACE" &>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $timeout ]]; then
            log_err "TUN interface $VLESS_TUN_IFACE not created after ${timeout}s"
            log_err "Check sing-box logs: journalctl -u sing-box -n 50"
            exit 1
        fi
    done
    ok "TUN interface $VLESS_TUN_IFACE is UP"

    # sing-box с auto_route=true сам настраивает маршруты через TUN
    # Обновляем iptables для MASQUERADE
    iptables -t nat -D POSTROUTING -o "$uplink" -j MASQUERADE 2>/dev/null || true
    if ! iptables -t nat -C POSTROUTING -o "$VLESS_TUN_IFACE" -j MASQUERADE &>/dev/null 2>&1; then
        iptables -t nat -A POSTROUTING -o "$VLESS_TUN_IFACE" -j MASQUERADE
    fi
    ok "MASQUERADE: $VLESS_TUN_IFACE"

    # Kill-switch: блокировать трафик клиентов мимо TUN
    killswitch_enable "$VLESS_TUN_IFACE"

    mkdir -p "$RUNTIME_DIR"
    echo "vless" > "$MODE_FILE"
    echo ""
    ok "VLESS (sing-box) ENABLED"
    echo -e "  Traffic: ${CYAN}LAN/WiFi → sing-box TUN ($VLESS_TUN_IFACE) → VLESS → Internet${NC}"
    log "Mode: vless"
}

vless_off() {
    log "Disabling VLESS (sing-box)..."

    local uplink
    uplink=$(get_uplink_iface)

    killswitch_disable

    systemctl stop sing-box 2>/dev/null || true
    ok "sing-box service stopped"

    # Восстановить iptables
    iptables -t nat -D POSTROUTING -o "$VLESS_TUN_IFACE" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "$uplink" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$uplink" -j MASQUERADE
    ok "MASQUERADE restored: $uplink"

    # Снять bypass routing (не вызывает restore_direct, поэтому отдельно)
    if [[ "$BYPASS_ENABLED" == "yes" && -f "$BYPASS_SH" ]]; then
        bash "$BYPASS_SH" off 2>/dev/null || true
    fi

    mkdir -p "$RUNTIME_DIR"
    echo "direct" > "$MODE_FILE"
    echo ""
    ok "Direct uplink ENABLED (VLESS off)"
    log "Mode: direct"
}

# =============================================================================
# Выключить любой активный VPN
# =============================================================================
vpn_off_any() {
    local mode
    mode=$(get_mode)
    case "$mode" in
        wg)      wg_off ;;
        amnezia) amnezia_off ;;
        vless)   vless_off ;;
        *)
            info "No VPN is active (mode: $mode)"
            ;;
    esac
}

# =============================================================================
# Статус всех протоколов
# =============================================================================
vpn_status() {
    local mode
    mode=$(get_mode)
    local uplink
    uplink=$(get_uplink_iface)

    echo ""
    echo "=========================================="
    echo "  LTE/WiFi Router + VPN Status"
    echo "=========================================="

    # Текущий режим
    echo ""
    case "$mode" in
        wg)      echo -e "  Active mode: ${GREEN}WireGuard${NC}" ;;
        amnezia) echo -e "  Active mode: ${GREEN}AmneziaWG${NC}" ;;
        vless)   echo -e "  Active mode: ${GREEN}VLESS (sing-box)${NC}" ;;
        *)       echo -e "  Active mode: ${YELLOW}Direct uplink (no VPN)${NC}" ;;
    esac
    echo -e "  Uplink: ${CYAN}$uplink${NC}"

    # --- Uplink интерфейсы ---
    echo ""
    echo "  [ Uplink ]"
    if ip addr show "$WWAN_IFACE" &>/dev/null 2>&1; then
        lte_ip=$(ip addr show "$WWAN_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
        ok "LTE ($WWAN_IFACE): UP | $lte_ip"
    else
        fail "LTE ($WWAN_IFACE): DOWN"
    fi

    WIFI_CLIENT_IFACE="${WIFI_CLIENT_IFACE:-wlan1}"
    if ip addr show "$WIFI_CLIENT_IFACE" &>/dev/null 2>&1; then
        wc_ip=$(ip addr show "$WIFI_CLIENT_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
        ok "WiFi upstream ($WIFI_CLIENT_IFACE): UP | $wc_ip"
    else
        info "WiFi upstream ($WIFI_CLIENT_IFACE): not connected"
    fi

    # --- WiFi AP ---
    echo ""
    echo "  [ WiFi AP ]"
    WIFI_AP_IFACE="${WIFI_AP_IFACE:-wlan0}"
    if pgrep -f "hostapd" > /dev/null 2>&1; then
        ap_ip=$(ip addr show "$WIFI_AP_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
        clients=$(iw dev "$WIFI_AP_IFACE" station dump 2>/dev/null | grep -c "^Station" || echo 0)
        ok "hostapd: RUNNING | IP: $ap_ip | Clients: $clients"
    else
        info "WiFi AP (hostapd): not running"
    fi

    # --- VPN протоколы ---
    echo ""
    echo "  [ VPN Protocols ]"

    # WireGuard
    if ip link show "$VPN_IFACE" &>/dev/null 2>&1; then
        vpn_ip=$(ip addr show "$VPN_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
        ok "WireGuard ($VPN_IFACE): UP | $vpn_ip"
        if command -v wg &>/dev/null; then
            hs=$(wg show "$VPN_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' || echo "0")
            if [[ -n "$hs" && "$hs" != "0" ]]; then
                age=$(( $(date +%s) - hs ))
                [[ $age -lt 180 ]] && info "  Handshake: ${age}s ago (OK)" || fail "  Handshake: ${age}s ago (stale!)"
            else
                fail "  No handshake yet"
            fi
        fi
    else
        info "WireGuard ($VPN_IFACE): DOWN"
    fi

    # AmneziaWG
    if ip link show "$AMNEZIA_IFACE" &>/dev/null 2>&1; then
        awg_ip=$(ip addr show "$AMNEZIA_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
        ok "AmneziaWG ($AMNEZIA_IFACE): UP | $awg_ip"
        if command -v awg &>/dev/null; then
            hs=$(awg show "$AMNEZIA_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' || echo "0")
            if [[ -n "$hs" && "$hs" != "0" ]]; then
                age=$(( $(date +%s) - hs ))
                [[ $age -lt 180 ]] && info "  Handshake: ${age}s ago (OK)" || fail "  Handshake: ${age}s ago (stale!)"
            fi
        fi
    else
        info "AmneziaWG ($AMNEZIA_IFACE): DOWN"
    fi

    # VLESS/sing-box
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        ok "sing-box (VLESS): RUNNING"
        if ip link show "$VLESS_TUN_IFACE" &>/dev/null 2>&1; then
            ok "TUN interface $VLESS_TUN_IFACE: UP"
        else
            info "TUN interface $VLESS_TUN_IFACE: not found"
        fi
    else
        info "sing-box (VLESS): not running"
    fi

    # --- Маршруты ---
    echo ""
    echo "  [ Default Routes ]"
    ip route show default 2>/dev/null | head -5 | while read -r line; do
        info "$line"
    done

    # --- Bypass routing ---
    echo ""
    echo "  [ Bypass routing ]"
    if [[ "$BYPASS_ENABLED" == "yes" ]]; then
        local bypass_mode_file="$RUNTIME_DIR/bypass_mode"
        if [[ -f "$bypass_mode_file" ]]; then
            local bmode; bmode=$(cat "$bypass_mode_file")
            ok "Bypass routing: ACTIVE (mode=$bmode)"
        else
            info "Bypass routing: ENABLED in config but not active (VPN is off)"
        fi
        local ip_cnt=0 net_cnt=0
        if command -v ipset &>/dev/null; then
            ip_cnt=$(ipset list ltemod_bypass_ip 2>/dev/null | grep -c '^[0-9]' || echo 0)
            net_cnt=$(ipset list ltemod_bypass_net 2>/dev/null | grep -c '^[0-9\.]' || echo 0)
        fi
        info "  ipsets: ltemod_bypass_ip=${ip_cnt}, ltemod_bypass_net=${net_cnt}"
        info "  To update lists: sudo list-manager update"
    else
        info "Bypass routing: disabled (BYPASS_ENABLED=no)"
    fi

    echo ""
    echo "  [ Commands ]"
    info "vpn-toggle wg on|off        — WireGuard"
    info "vpn-toggle amnezia on|off   — AmneziaWG (обфускация)"
    info "vpn-toggle vless on|off     — VLESS (sing-box)"
    info "vpn-toggle status           — этот экран"
    info "bypass-routing status       — состояние bypass routing"
    info "list-manager update         — скачать и загрузить списки"
    echo "=========================================="
}

# =============================================================================
# Точка входа
# =============================================================================

# Разобрать аргументы
# Форматы:
#   vpn-toggle status
#   vpn-toggle off                (выключить текущий)
#   vpn-toggle wg on|off
#   vpn-toggle amnezia on|off
#   vpn-toggle vless on|off
#   vpn-toggle on|off             (обратная совместимость — работает с WG)

ARG1="${1:-status}"
ARG2="${2:-}"

# Обратная совместимость: vpn-toggle on/off без протокола → WireGuard
if [[ "$ARG1" == "on" ]]; then
    ARG2="on"
    ARG1="wg"
elif [[ "$ARG1" == "off" ]]; then
    ARG1="off_any"
fi

# Команды без root не требуют elevated
if [[ $EUID -ne 0 && "$ARG1" != "status" ]]; then
    log_err "Commands require root: sudo $0 $*"
    echo "Usage: sudo $0 [wg|amnezia|vless] [on|off]"
    exit 1
fi

case "$ARG1" in
    wg)
        case "$ARG2" in
            on)  wg_on ;;
            off) wg_off ;;
            *)   echo "Usage: $0 wg {on|off}"; exit 1 ;;
        esac
        ;;
    amnezia)
        case "$ARG2" in
            on)  amnezia_on ;;
            off) amnezia_off ;;
            *)   echo "Usage: $0 amnezia {on|off}"; exit 1 ;;
        esac
        ;;
    vless)
        case "$ARG2" in
            on)  vless_on ;;
            off) vless_off ;;
            *)   echo "Usage: $0 vless {on|off}"; exit 1 ;;
        esac
        ;;
    off_any)
        vpn_off_any
        ;;
    status)
        vpn_status
        ;;
    *)
        echo "Usage: $0 [wg|amnezia|vless] {on|off}"
        echo "       $0 off     — disable any active VPN"
        echo "       $0 status  — show all protocols status"
        exit 1
        ;;
esac
