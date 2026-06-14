#!/bin/bash
# =============================================================================
# modem-watchdog.sh — мониторинг uplink-соединения и автопереподключение
# Запускается по таймеру: lte-watchdog.timer (каждые 60 сек)
# Поддерживает режимы: lte | eth | wifi-client | auto
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

PING_HOST="${PING_HOST:-8.8.8.8}"
MAX_RECONNECT_ATTEMPTS="${MAX_RECONNECT_ATTEMPTS:-5}"
RECONNECT_COUNTER_FILE="${RECONNECT_COUNTER_FILE:-/run/ltemod/reconnect_count}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/ltemod}"
MODE_FILE="${MODE_FILE:-/run/ltemod/mode}"
WWAN_IFACE="${WWAN_IFACE:-wwan0}"
LAN_IFACE="${LAN_IFACE:-end0}"
WIFI_CLIENT_IFACE="${WIFI_CLIENT_IFACE:-wlan1}"
VPN_IFACE="${VPN_IFACE:-wg0}"
AMNEZIA_IFACE="${AMNEZIA_IFACE:-awg0}"
VLESS_TUN_IFACE="${VLESS_TUN_IFACE:-tun0}"
UPLINK_MODE="${UPLINK_MODE:-lte}"
NM_CON_NAME="${NM_CON_NAME:-lte-connection}"
LOG_TAG="${LOG_TAG:-ltemod}"

log() {
    logger -t "${LOG_TAG}-watchdog" "$*"
}

log_err() {
    logger -t "${LOG_TAG}-watchdog" -p user.err "$*"
}

mkdir -p "$RUNTIME_DIR"

# ---------------------------------------------------------------------------
# Счётчик попыток
# ---------------------------------------------------------------------------
get_counter() {
    [[ -f "$RECONNECT_COUNTER_FILE" ]] && cat "$RECONNECT_COUNTER_FILE" || echo "0"
}

set_counter()   { echo "$1" > "$RECONNECT_COUNTER_FILE"; }
reset_counter() { set_counter 0; }

# ---------------------------------------------------------------------------
# Режим VPN
# ---------------------------------------------------------------------------
get_mode() {
    [[ -f "$MODE_FILE" ]] && cat "$MODE_FILE" || echo "direct"
}

mode_is_vpn() {
    case "$1" in
        wg|amnezia|vless) return 0 ;;
        *)                return 1 ;;
    esac
}

vpn_iface_for_mode() {
    case "$1" in
        wg)      echo "$VPN_IFACE" ;;
        amnezia) echo "$AMNEZIA_IFACE" ;;
        vless)   echo "$VLESS_TUN_IFACE" ;;
        *)       echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# Определить активный uplink интерфейс
# ---------------------------------------------------------------------------
get_active_uplink_iface() {
    # Читаем из runtime файла (записывается setup-uplink.sh и setup-routing.sh)
    local saved_iface
    saved_iface=$(cat "$RUNTIME_DIR/uplink_iface" 2>/dev/null || echo "")
    if [[ -n "$saved_iface" ]] && ip link show "$saved_iface" &>/dev/null; then
        echo "$saved_iface"
        return 0
    fi

    # Fallback: по UPLINK_MODE из конфига
    case "$UPLINK_MODE" in
        eth|ethernet)      echo "$LAN_IFACE" ;;
        wifi-client|wifi)  echo "$WIFI_CLIENT_IFACE" ;;
        *)                 echo "$WWAN_IFACE" ;;
    esac
}

# ---------------------------------------------------------------------------
# Проверить uplink интерфейс
# ---------------------------------------------------------------------------
check_uplink_iface() {
    local iface="$1"
    if ! ip link show "$iface" &>/dev/null; then
        return 1
    fi
    if ! ip addr show "$iface" 2>/dev/null | grep -q "inet "; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Проверить VPN интерфейс
# ---------------------------------------------------------------------------
check_vpn_iface() {
    local iface
    iface=$(vpn_iface_for_mode "$(get_mode)")
    [[ -z "$iface" ]] && return 1
    ip link show "$iface" &>/dev/null
}

# ---------------------------------------------------------------------------
# Проверить интернет (3 попытки с задержкой)
# ---------------------------------------------------------------------------
check_internet() {
    local i
    for (( i=1; i<=3; i++ )); do
        ping -c 1 -W 5 "$PING_HOST" &>/dev/null && return 0
        sleep 2
    done
    return 1
}

# ---------------------------------------------------------------------------
# Переподключение: LTE
# ---------------------------------------------------------------------------
reconnect_lte() {
    log "Attempting LTE reconnection..."

    if nmcli connection show "$NM_CON_NAME" &>/dev/null; then
        log "Restarting NM connection: $NM_CON_NAME"
        nmcli connection down "$NM_CON_NAME" 2>/dev/null || true
        sleep 2
        nmcli connection up "$NM_CON_NAME" && {
            log "NM reconnection successful"
            return 0
        }
        log_err "NM reconnection failed, trying full reconnect..."
    fi

    local connect_script="/usr/local/bin/ltemod/connect-modem.sh"
    [[ ! -f "$connect_script" ]] && connect_script="$(dirname "$0")/connect-modem.sh"

    if [[ -f "$connect_script" ]]; then
        bash "$connect_script" && { log "Full LTE reconnection successful"; return 0; }
        log_err "Full LTE reconnection failed"
    else
        log_err "connect-modem.sh not found"
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Переподключение: Ethernet (обновить DHCP)
# ---------------------------------------------------------------------------
reconnect_eth() {
    log "Attempting Ethernet DHCP renewal on $LAN_IFACE..."

    # Попробовать обновить через NM
    local nm_con
    nm_con=$(nmcli -g NAME,DEVICE connection show --active 2>/dev/null | \
             grep ":${LAN_IFACE}$" | cut -d: -f1 | head -1 || echo "")
    if [[ -n "$nm_con" ]]; then
        nmcli connection down "$nm_con" 2>/dev/null || true
        sleep 1
        nmcli connection up "$nm_con" && { log "Ethernet reconnection via NM successful"; return 0; }
    fi

    # Прямой DHCP
    if command -v dhclient &>/dev/null; then
        dhclient -1 -t 20 "$LAN_IFACE" 2>/dev/null && {
            log "Ethernet DHCP renewal successful"
            return 0
        }
    elif command -v dhcpcd &>/dev/null; then
        dhcpcd -n --timeout 20 "$LAN_IFACE" 2>/dev/null && {
            log "Ethernet DHCP renewal successful"
            return 0
        }
    fi

    log_err "Ethernet reconnection failed — check cable connection"
    return 1
}

# ---------------------------------------------------------------------------
# Переподключение: WiFi client
# ---------------------------------------------------------------------------
reconnect_wifi_client() {
    log "Attempting WiFi client reconnection (SSID: ${WIFI_CLIENT_SSID:-?})..."

    local script="/usr/local/bin/ltemod/setup-wifi-client.sh"
    [[ ! -f "$script" ]] && script="$(dirname "$0")/../wifi/setup-wifi-client.sh"

    if [[ -f "$script" ]]; then
        bash "$script" disconnect 2>/dev/null || true
        sleep 2
        bash "$script" connect && { log "WiFi client reconnection successful"; return 0; }
        log_err "WiFi client reconnection failed"
    else
        log_err "setup-wifi-client.sh not found"
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Универсальное переподключение
# ---------------------------------------------------------------------------
reconnect_uplink() {
    local active_mode
    active_mode=$(cat "$RUNTIME_DIR/uplink_mode" 2>/dev/null || echo "$UPLINK_MODE")
    case "$active_mode" in
        lte)         reconnect_lte ;;
        eth)         reconnect_eth ;;
        wifi-client) reconnect_wifi_client ;;
        *)           reconnect_lte ;;
    esac
}

# ---------------------------------------------------------------------------
# Восстановить VPN если был активен
# ---------------------------------------------------------------------------
reconnect_vpn() {
    local mode
    mode=$(get_mode)
    if mode_is_vpn "$mode"; then
        log "VPN mode active ($mode), re-enabling..."
        local toggle_script="/usr/local/bin/ltemod/vpn-toggle.sh"
        [[ ! -f "$toggle_script" ]] && \
            toggle_script="$(dirname "$0")/../network/vpn-toggle.sh"
        if [[ -f "$toggle_script" ]]; then
            bash "$toggle_script" "$mode" on || log_err "Failed to re-enable VPN ($mode)"
        else
            log_err "vpn-toggle.sh not found, cannot re-enable VPN"
        fi
    fi
}

# ===========================================================================
# === Главная логика ===
# ===========================================================================

log "Watchdog check started (UPLINK_MODE=${UPLINK_MODE})"

# Определить активный uplink интерфейс
uplink_iface=$(get_active_uplink_iface)

# Проверить uplink интерфейс
uplink_ok=true
if ! check_uplink_iface "$uplink_iface"; then
    uplink_ok=false
    log_err "Uplink interface $uplink_iface is DOWN or has no IP (mode: $UPLINK_MODE)"
fi

# Проверить VPN если активен
vpn_mode=$(get_mode)
if mode_is_vpn "$vpn_mode"; then
    if ! check_vpn_iface; then
        log_err "VPN interface $(vpn_iface_for_mode "$vpn_mode") is DOWN while VPN mode ($vpn_mode) is active"
    fi
fi

# Проверить интернет
if $uplink_ok && check_internet; then
    log "Connectivity OK (ping $PING_HOST successful via $uplink_iface)"
    reset_counter
    log "Watchdog check passed"
    exit 0
fi

# Интернет недоступен — пробуем переподключиться
counter=$(get_counter)
counter=$((counter + 1))
set_counter "$counter"

log_err "Connectivity FAILED (attempt $counter/$MAX_RECONNECT_ATTEMPTS, uplink: $uplink_iface)"

if [[ $counter -ge $MAX_RECONNECT_ATTEMPTS ]]; then
    log_err "Max reconnection attempts ($MAX_RECONNECT_ATTEMPTS) reached!"
    log_err "Rebooting system to recover..."
    sleep 2
    if command -v systemctl &>/dev/null; then
        systemctl reboot || reboot || /sbin/reboot
    else
        reboot || /sbin/reboot
    fi
    exit 1
fi

# Попытка переподключения
if reconnect_uplink; then
    sleep 5
    reconnect_vpn
    sleep 5
    if check_internet; then
        log "Reconnection successful, connectivity restored"
        reset_counter
        exit 0
    else
        log_err "Reconnection done but internet still unreachable"
    fi
else
    log_err "Reconnection failed (attempt $counter/$MAX_RECONNECT_ATTEMPTS)"
fi

exit 1
