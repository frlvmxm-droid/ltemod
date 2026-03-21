#!/bin/bash
# =============================================================================
# setup-routing.sh — базовая настройка маршрутизации
# Режим по умолчанию: прямой uplink (LTE / WiFi / Ethernet)
# Вызывается из lte-modem.service после успешного подключения модема
# =============================================================================

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

WWAN_IFACE="${WWAN_IFACE:-wwan0}"
LAN_IFACE="${LAN_IFACE:-end0}"
WIFI_AP_IFACE="${WIFI_AP_IFACE:-wlan0}"
WIFI_CLIENT_IFACE="${WIFI_CLIENT_IFACE:-wlan1}"
WIFI_AP_ENABLED="${WIFI_AP_ENABLED:-yes}"
UPLINK_PRIORITY="${UPLINK_PRIORITY:-lte wifi eth}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/ltemod}"
MODE_FILE="${MODE_FILE:-/run/ltemod/mode}"
LOG_TAG="${LOG_TAG:-ltemod}"

log() {
    logger -t "$LOG_TAG" "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
    logger -t "$LOG_TAG" -p user.err "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

if [[ $EUID -ne 0 ]]; then
    log_err "Must be run as root"
    exit 1
fi

mkdir -p "$RUNTIME_DIR"

log "=== Setting up routing ==="

# --- IP Forwarding ---
log "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1 || true

SYSCTL_CONF="/etc/sysctl.d/99-ltemod.conf"
if [[ ! -f "$SYSCTL_CONF" ]]; then
    cat > "$SYSCTL_CONF" <<EOF
# ltemod: IP forwarding for router
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
    log "Created $SYSCTL_CONF"
fi

# ---------------------------------------------------------------------------
# Определить активный uplink интерфейс
# Порядок: lte → wifi (клиент) → eth (кабель от другого роутера)
# ---------------------------------------------------------------------------
get_active_uplink() {
    for uplink in $UPLINK_PRIORITY; do
        local iface=""
        case "$uplink" in
            lte)  iface="$WWAN_IFACE" ;;
            wifi) iface="$WIFI_CLIENT_IFACE" ;;
            eth)  iface="$LAN_IFACE" ;;
        esac

        if [[ -z "$iface" ]]; then
            continue
        fi

        # Интерфейс должен быть UP и иметь IP адрес
        if ip link show "$iface" &>/dev/null && \
           ip addr show "$iface" 2>/dev/null | grep -q "inet "; then
            echo "$iface"
            return 0
        fi
    done

    # Fallback: использовать wwan0 даже если нет IP (модем ещё подключается)
    echo "$WWAN_IFACE"
}

# --- Ждать появления хотя бы одного uplink интерфейса ---
timeout=30
elapsed=0
while true; do
    active_uplink=$(get_active_uplink)

    # Если нашли реальный uplink с IP — выходим из ожидания
    if ip addr show "$active_uplink" 2>/dev/null | grep -q "inet "; then
        break
    fi

    # Для LTE — ждём появления интерфейса (без IP пока)
    if [[ "$active_uplink" == "$WWAN_IFACE" ]] && \
       ip link show "$WWAN_IFACE" &>/dev/null; then
        break
    fi

    sleep 1
    elapsed=$((elapsed + 1))
    if [[ $elapsed -ge $timeout ]]; then
        log_err "No uplink interface found after ${timeout}s (tried: $UPLINK_PRIORITY)"
        log_err "Continuing with fallback: $WWAN_IFACE"
        active_uplink="$WWAN_IFACE"
        break
    fi
done

log "Active uplink: $active_uplink"
echo "$active_uplink" > "$RUNTIME_DIR/uplink_iface"

# --- iptables NAT: прямой режим ---
log "Configuring iptables for direct routing via $active_uplink..."

# Очистить старые MASQUERADE правила
iptables -t nat -L POSTROUTING --line-numbers -n 2>/dev/null | \
    grep -E "MASQUERADE" | awk '{print $1}' | sort -rn | \
    while read -r num; do iptables -t nat -D POSTROUTING "$num" 2>/dev/null || true; done

# MASQUERADE для основного uplink
if ! iptables -t nat -C POSTROUTING -o "$active_uplink" -j MASQUERADE &>/dev/null; then
    iptables -t nat -A POSTROUTING -o "$active_uplink" -j MASQUERADE
    log "Added MASQUERADE on $active_uplink"
fi

# FORWARD: LAN Ethernet → uplink
if [[ "$WIFI_AP_ENABLED" != "yes" ]] || [[ "$active_uplink" != "$WIFI_AP_IFACE" ]]; then
    if ! iptables -C FORWARD -i "$LAN_IFACE" -o "$active_uplink" -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -i "$LAN_IFACE" -o "$active_uplink" -j ACCEPT
    fi
    if ! iptables -C FORWARD -i "$active_uplink" -o "$LAN_IFACE" \
            -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -i "$active_uplink" -o "$LAN_IFACE" \
            -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi
fi

# FORWARD: WiFi AP → uplink (если AP включена и uplink — не сам AP интерфейс)
if [[ "$WIFI_AP_ENABLED" == "yes" ]]; then
    if ! iptables -C FORWARD -i "$WIFI_AP_IFACE" -o "$active_uplink" -j ACCEPT &>/dev/null 2>&1; then
        iptables -A FORWARD -i "$WIFI_AP_IFACE" -o "$active_uplink" -j ACCEPT
    fi
    if ! iptables -C FORWARD -i "$active_uplink" -o "$WIFI_AP_IFACE" \
            -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null 2>&1; then
        iptables -A FORWARD -i "$active_uplink" -o "$WIFI_AP_IFACE" \
            -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi
fi

# --- Сохранить текущий режим ---
echo "direct" > "$MODE_FILE"
log "Routing mode set to: direct ($active_uplink)"

log "=== Routing setup complete ==="
log "Uplink: $active_uplink | LAN: $LAN_IFACE | WiFi AP: ${WIFI_AP_IFACE} (enabled=${WIFI_AP_ENABLED})"
log "Use 'vpn-toggle [wg|amnezia|vless] on' to enable VPN"
