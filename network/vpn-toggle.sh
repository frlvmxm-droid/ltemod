#!/bin/bash
# =============================================================================
# vpn-toggle.sh — переключение между режимами VPN и прямого LTE
#
# Использование:
#   vpn-toggle.sh on     — включить VPN (трафик через WireGuard)
#   vpn-toggle.sh off    — выключить VPN (прямой LTE)
#   vpn-toggle.sh status — показать текущий режим
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

WWAN_IFACE="${WWAN_IFACE:-wwan0}"
LAN_IFACE="${LAN_IFACE:-end0}"
VPN_IFACE="${VPN_IFACE:-wg0}"
WG_CONFIG="${WG_CONFIG:-/etc/wireguard/wg0.conf}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/ltemod}"
MODE_FILE="${MODE_FILE:-/run/ltemod/mode}"
LOG_TAG="${LOG_TAG:-ltemod}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    logger -t "${LOG_TAG}-vpn" "$*"
    echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"
}

log_err() {
    logger -t "${LOG_TAG}-vpn" -p user.err "$*"
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2
}

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
info() { echo -e "  ${YELLOW}→${NC} $*"; }

get_mode() {
    [[ -f "$MODE_FILE" ]] && cat "$MODE_FILE" || echo "direct"
}

# --- Включить VPN ---
vpn_on() {
    log "Enabling VPN mode..."

    # Проверить что WireGuard конфиг есть
    if [[ ! -f "$WG_CONFIG" ]]; then
        log_err "WireGuard config not found: $WG_CONFIG"
        log_err "Run: sudo setup-vpn.sh /path/to/wg0.conf"
        exit 1
    fi

    # Если VPN уже активен
    if ip link show "$VPN_IFACE" &>/dev/null; then
        info "WireGuard interface $VPN_IFACE already up"
    else
        log "Starting WireGuard interface $VPN_IFACE..."
        wg-quick up "$VPN_IFACE" || {
            log_err "Failed to start WireGuard"
            exit 1
        }
        ok "WireGuard $VPN_IFACE started"
    fi

    # Добавить маршруты (wg-quick не добавляет их при Table=off)
    log "Configuring routes through $VPN_IFACE..."

    # Получить IP через WireGuard для маршрутизации
    wg_peer_endpoint=$(wg show "$VPN_IFACE" endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1 | head -1 || echo "")

    # Защитный маршрут: endpoint сервера идёт напрямую через LTE (не через VPN)
    if [[ -n "$wg_peer_endpoint" ]]; then
        default_gw=$(ip route show default dev "$WWAN_IFACE" 2>/dev/null | awk '/via/ {print $3}' | head -1 || true)
        if [[ -n "$default_gw" ]]; then
            # Маршрут к VPN серверу через LTE (чтобы не было петли)
            if ! ip route show "$wg_peer_endpoint" | grep -q "$WWAN_IFACE"; then
                ip route add "$wg_peer_endpoint/32" via "$default_gw" dev "$WWAN_IFACE" 2>/dev/null || true
                log "Added direct route to VPN endpoint: $wg_peer_endpoint via $default_gw"
            fi
        fi
    fi

    # Дефолтный маршрут через WireGuard
    # Удалить старый дефолт через LTE (сохранить для возврата)
    lte_default=$(ip route show default 2>/dev/null | grep "$WWAN_IFACE" | head -1 || echo "")

    # Добавить дефолт через wg0 с меньшей метрикой
    if ! ip route show default dev "$VPN_IFACE" &>/dev/null 2>&1; then
        ip route add default dev "$VPN_IFACE" metric 100 2>/dev/null || \
        ip route replace default dev "$VPN_IFACE" metric 100
        ok "Default route set via $VPN_IFACE"
    fi

    # Изменить метрику LTE маршрута чтобы он был резервным
    if [[ -n "$lte_default" ]]; then
        ip route del default dev "$WWAN_IFACE" 2>/dev/null || true
        ip route add default dev "$WWAN_IFACE" metric 200 2>/dev/null || true
        log "LTE route moved to metric 200 (backup)"
    fi

    # Обновить iptables: переключить MASQUERADE с LTE на VPN
    log "Updating iptables rules..."
    iptables -t nat -D POSTROUTING -o "$WWAN_IFACE" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "$VPN_IFACE" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$VPN_IFACE" -j MASQUERADE
    ok "MASQUERADE switched to $VPN_IFACE"

    # Обновить FORWARD правила
    iptables -D FORWARD -i "$LAN_IFACE" -o "$WWAN_IFACE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$WWAN_IFACE" -o "$LAN_IFACE" \
        -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    if ! iptables -C FORWARD -i "$LAN_IFACE" -o "$VPN_IFACE" -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -i "$LAN_IFACE" -o "$VPN_IFACE" -j ACCEPT
    fi
    if ! iptables -C FORWARD -i "$VPN_IFACE" -o "$LAN_IFACE" \
            -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -i "$VPN_IFACE" -o "$LAN_IFACE" \
            -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi
    ok "FORWARD rules updated for VPN"

    # Сохранить режим
    mkdir -p "$RUNTIME_DIR"
    echo "vpn" > "$MODE_FILE"

    echo ""
    ok "VPN mode ENABLED"
    echo -e "  Traffic: ${CYAN}LAN → WireGuard ($VPN_IFACE) → Internet${NC}"
    log "Mode switched to: VPN"
}

# --- Выключить VPN ---
vpn_off() {
    log "Disabling VPN mode..."

    # Восстановить дефолтный маршрут через LTE
    log "Restoring direct LTE routing..."
    ip route del default dev "$VPN_IFACE" metric 100 2>/dev/null || true

    # Восстановить основной маршрут через LTE (убрать backup метрику)
    if ip route show default dev "$WWAN_IFACE" &>/dev/null 2>&1; then
        ip route del default dev "$WWAN_IFACE" metric 200 2>/dev/null || true
        ip route add default dev "$WWAN_IFACE" metric 100 2>/dev/null || true
    fi
    ok "Default route restored via $WWAN_IFACE"

    # Удалить маршрут к endpoint VPN сервера
    wg_peer_endpoint=""
    if ip link show "$VPN_IFACE" &>/dev/null; then
        wg_peer_endpoint=$(wg show "$VPN_IFACE" endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1 | head -1 || echo "")
    fi

    # Остановить WireGuard
    if ip link show "$VPN_IFACE" &>/dev/null; then
        log "Stopping WireGuard interface $VPN_IFACE..."
        wg-quick down "$VPN_IFACE" || {
            log_err "Failed to stop WireGuard, forcing..."
            ip link delete "$VPN_IFACE" 2>/dev/null || true
        }
        ok "WireGuard $VPN_IFACE stopped"
    else
        info "WireGuard $VPN_IFACE was already down"
    fi

    # Удалить маршрут к VPN серверу
    if [[ -n "$wg_peer_endpoint" ]]; then
        ip route del "$wg_peer_endpoint/32" 2>/dev/null || true
    fi

    # Обновить iptables: вернуть MASQUERADE на LTE
    log "Restoring iptables rules..."
    iptables -t nat -D POSTROUTING -o "$VPN_IFACE" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "$WWAN_IFACE" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$WWAN_IFACE" -j MASQUERADE
    ok "MASQUERADE restored to $WWAN_IFACE"

    # Обновить FORWARD правила
    iptables -D FORWARD -i "$LAN_IFACE" -o "$VPN_IFACE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$VPN_IFACE" -o "$LAN_IFACE" \
        -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    if ! iptables -C FORWARD -i "$LAN_IFACE" -o "$WWAN_IFACE" -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -i "$LAN_IFACE" -o "$WWAN_IFACE" -j ACCEPT
    fi
    if ! iptables -C FORWARD -i "$WWAN_IFACE" -o "$LAN_IFACE" \
            -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -i "$WWAN_IFACE" -o "$LAN_IFACE" \
            -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi
    ok "FORWARD rules updated for direct LTE"

    # Сохранить режим
    mkdir -p "$RUNTIME_DIR"
    echo "direct" > "$MODE_FILE"

    echo ""
    ok "Direct LTE mode ENABLED"
    echo -e "  Traffic: ${CYAN}LAN → LTE ($WWAN_IFACE) → Internet${NC}"
    log "Mode switched to: direct LTE"
}

# --- Статус ---
vpn_status() {
    mode=$(get_mode)
    echo ""
    echo "=============================="
    echo "  LTE/VPN Mode Status"
    echo "=============================="

    if [[ "$mode" == "vpn" ]]; then
        echo -e "  Current mode: ${GREEN}VPN${NC}"
        echo -e "  Path: LAN → WireGuard ($VPN_IFACE) → Internet"
    else
        echo -e "  Current mode: ${YELLOW}Direct LTE${NC}"
        echo -e "  Path: LAN → LTE ($WWAN_IFACE) → Internet"
    fi

    echo ""
    echo "  Interfaces:"

    # LTE
    if ip link show "$WWAN_IFACE" &>/dev/null; then
        lte_ip=$(ip addr show "$WWAN_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
        ok "LTE ($WWAN_IFACE): UP | $lte_ip"
    else
        fail "LTE ($WWAN_IFACE): DOWN"
    fi

    # VPN
    if ip link show "$VPN_IFACE" &>/dev/null; then
        vpn_ip=$(ip addr show "$VPN_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
        ok "VPN ($VPN_IFACE): UP | $vpn_ip"
        if command -v wg &>/dev/null; then
            hs=$(wg show "$VPN_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' || echo "0")
            if [[ -n "$hs" && "$hs" != "0" ]]; then
                age=$(( $(date +%s) - hs ))
                if [[ $age -lt 180 ]]; then
                    info "  Last handshake: ${age}s ago"
                else
                    fail "  Last handshake: ${age}s ago (stale!)"
                fi
            else
                fail "  No handshake yet"
            fi
        fi
    else
        info "VPN ($VPN_IFACE): DOWN"
    fi

    echo ""
    echo "  Default route:"
    ip route show default 2>/dev/null | while read -r line; do
        info "$line"
    done

    echo ""
    echo "  Commands:"
    if [[ "$mode" == "vpn" ]]; then
        info "vpn-toggle.sh off   — switch to direct LTE"
    else
        info "vpn-toggle.sh on    — enable VPN"
    fi
    echo "=============================="
}

# === Точка входа ===

CMD="${1:-status}"

if [[ $EUID -ne 0 && "$CMD" != "status" ]]; then
    log_err "Commands 'on' and 'off' require root privileges"
    echo "Usage: sudo $0 on|off|status"
    exit 1
fi

case "$CMD" in
    on)     vpn_on ;;
    off)    vpn_off ;;
    status) vpn_status ;;
    *)
        echo "Usage: $0 {on|off|status}"
        echo "  on     — enable VPN (route through WireGuard)"
        echo "  off    — disable VPN (direct LTE)"
        echo "  status — show current mode"
        exit 1
        ;;
esac
