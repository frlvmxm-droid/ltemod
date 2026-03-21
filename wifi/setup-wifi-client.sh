#!/bin/bash
# =============================================================================
# setup-wifi-client.sh — подключение к upstream WiFi роутеру
# Создаёт виртуальный STA интерфейс поверх основного WiFi AP интерфейса
#
# Использование:
#   sudo setup-wifi-client.sh connect   — подключиться к upstream WiFi
#   sudo setup-wifi-client.sh disconnect — отключиться
#   sudo setup-wifi-client.sh status    — текущий статус
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

WIFI_AP_IFACE="${WIFI_AP_IFACE:-wlan0}"
WIFI_CLIENT_IFACE="${WIFI_CLIENT_IFACE:-wlan1}"
WIFI_CLIENT_SSID="${WIFI_CLIENT_SSID:-}"
WIFI_CLIENT_PASSWORD="${WIFI_CLIENT_PASSWORD:-}"
LOG_TAG="${LOG_TAG:-ltemod}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { logger -t "${LOG_TAG}-wifi" "$*"; echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
log_err() { logger -t "${LOG_TAG}-wifi" -p user.err "$*"; echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
fail()    { echo -e "  ${RED}✗${NC} $*"; }
info()    { echo -e "  ${YELLOW}→${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
    log_err "Must be run as root"
    exit 1
fi

# ---------------------------------------------------------------------------
# Подключиться к upstream WiFi
# ---------------------------------------------------------------------------
wifi_connect() {
    if [[ -z "$WIFI_CLIENT_SSID" ]]; then
        log_err "WIFI_CLIENT_SSID is not set in ltemod.conf"
        exit 1
    fi

    log "Connecting to upstream WiFi: '$WIFI_CLIENT_SSID'..."

    # Создать виртуальный managed интерфейс для клиентского режима
    # (AP6256 поддерживает concurrent AP+STA через виртуальный iface)
    if ! ip link show "$WIFI_CLIENT_IFACE" &>/dev/null; then
        log "Creating virtual STA interface $WIFI_CLIENT_IFACE..."
        iw dev "$WIFI_AP_IFACE" interface add "$WIFI_CLIENT_IFACE" type managed 2>/dev/null || {
            log_err "Failed to create virtual interface $WIFI_CLIENT_IFACE"
            log_err "Your WiFi driver may not support concurrent AP+STA mode"
            exit 1
        }
        ok "Virtual STA interface $WIFI_CLIENT_IFACE created"
    else
        info "Interface $WIFI_CLIENT_IFACE already exists"
    fi

    ip link set "$WIFI_CLIENT_IFACE" up

    # Подключить через NetworkManager
    if [[ -n "$WIFI_CLIENT_PASSWORD" ]]; then
        nmcli dev wifi connect "$WIFI_CLIENT_SSID" \
            password "$WIFI_CLIENT_PASSWORD" \
            ifname "$WIFI_CLIENT_IFACE" \
            name "ltemod-wifi-upstream" || {
            log_err "Failed to connect to '$WIFI_CLIENT_SSID'"
            exit 1
        }
    else
        # Открытая сеть
        nmcli dev wifi connect "$WIFI_CLIENT_SSID" \
            ifname "$WIFI_CLIENT_IFACE" \
            name "ltemod-wifi-upstream" || {
            log_err "Failed to connect to open network '$WIFI_CLIENT_SSID'"
            exit 1
        }
    fi

    # Ждать IP адреса
    timeout=20
    elapsed=0
    while ! ip addr show "$WIFI_CLIENT_IFACE" | grep -q "inet "; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $timeout ]]; then
            log_err "No IP received on $WIFI_CLIENT_IFACE after ${timeout}s"
            exit 1
        fi
    done

    client_ip=$(ip addr show "$WIFI_CLIENT_IFACE" | grep "inet " | awk '{print $2}')
    ok "Connected to '$WIFI_CLIENT_SSID': $client_ip on $WIFI_CLIENT_IFACE"
    log "WiFi upstream connected"
}

# ---------------------------------------------------------------------------
# Отключиться
# ---------------------------------------------------------------------------
wifi_disconnect() {
    log "Disconnecting WiFi upstream..."

    nmcli connection down "ltemod-wifi-upstream" 2>/dev/null || true
    nmcli connection delete "ltemod-wifi-upstream" 2>/dev/null || true

    # Удалить виртуальный интерфейс
    if ip link show "$WIFI_CLIENT_IFACE" &>/dev/null; then
        ip link set "$WIFI_CLIENT_IFACE" down 2>/dev/null || true
        iw dev "$WIFI_CLIENT_IFACE" del 2>/dev/null || true
        ok "Interface $WIFI_CLIENT_IFACE removed"
    fi

    ok "WiFi upstream disconnected"
}

# ---------------------------------------------------------------------------
# Статус
# ---------------------------------------------------------------------------
wifi_status() {
    echo ""
    echo "=============================="
    echo "  WiFi Client Status"
    echo "=============================="

    if ip link show "$WIFI_CLIENT_IFACE" &>/dev/null; then
        client_ip=$(ip addr show "$WIFI_CLIENT_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
        ok "Interface $WIFI_CLIENT_IFACE: UP | IP: $client_ip"

        # Получить информацию о подключении через iw
        ssid_info=$(iw dev "$WIFI_CLIENT_IFACE" link 2>/dev/null | grep -E "SSID|signal|tx bitrate" || echo "")
        if [[ -n "$ssid_info" ]]; then
            while IFS= read -r line; do
                info "$line"
            done <<< "$ssid_info"
        fi
    else
        fail "Interface $WIFI_CLIENT_IFACE: not found (not connected)"
    fi

    # NetworkManager статус
    nm_state=$(nmcli -g GENERAL.STATE connection show "ltemod-wifi-upstream" 2>/dev/null || echo "not configured")
    info "NM connection: $nm_state"
    echo "=============================="
}

# ---------------------------------------------------------------------------
# Сканирование доступных сетей
# ---------------------------------------------------------------------------
wifi_scan() {
    log "Scanning WiFi networks..."
    nmcli dev wifi list ifname "$WIFI_AP_IFACE" 2>/dev/null || \
    iw dev "$WIFI_AP_IFACE" scan 2>/dev/null | grep -E "SSID:|signal:|freq:" || \
    echo "No scan results (may need 'iw dev scan' with rfkill unblocked)"
}

# === Точка входа ===
CMD="${1:-status}"
case "$CMD" in
    connect)    wifi_connect ;;
    disconnect) wifi_disconnect ;;
    status)     wifi_status ;;
    scan)       wifi_scan ;;
    *)
        echo "Usage: $0 {connect|disconnect|status|scan}"
        echo "  connect    — connect to upstream WiFi router"
        echo "  disconnect — disconnect and remove virtual interface"
        echo "  status     — show current connection status"
        echo "  scan       — scan available WiFi networks"
        exit 1
        ;;
esac
