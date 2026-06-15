#!/bin/bash
# =============================================================================
# setup-uplink.sh — управление uplink-подключением
#
# Поддерживаемые режимы (UPLINK_MODE в ltemod.conf):
#   lte         — LTE-модем (Sierra Wireless EM7565 через MBIM/QMI)
#   eth         — Ethernet кабель от другого роутера (DHCP на LAN_IFACE)
#   wifi-client — Подключение к upstream WiFi роутеру
#   auto        — автоматический выбор по UPLINK_PRIORITY
#
# Использование:
#   setup-uplink start   — запустить uplink + setup-routing.sh
#   setup-uplink stop    — остановить uplink
#   setup-uplink status  — текущий статус
#   setup-uplink restart — stop + start
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

UPLINK_MODE="${UPLINK_MODE:-lte}"
UPLINK_PRIORITY="${UPLINK_PRIORITY:-lte wifi eth}"
WWAN_IFACE="${WWAN_IFACE:-wwan0}"
LAN_IFACE="${LAN_IFACE:-end0}"
WIFI_CLIENT_IFACE="${WIFI_CLIENT_IFACE:-wlan1}"
WIFI_AP_IFACE="${WIFI_AP_IFACE:-wlan0}"
NM_CON_NAME="${NM_CON_NAME:-lte-connection}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/ltemod}"
LOG_TAG="${LOG_TAG:-ltemod}"

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

log()     { logger -t "${LOG_TAG}-uplink" "$*"; echo "[$(date '+%H:%M:%S')] $*"; }
log_err() { logger -t "${LOG_TAG}-uplink" -p user.err "$*"; echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    log_err "Must be run as root"
    exit 1
fi

mkdir -p "$RUNTIME_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

find_script() {
    local name="$1"
    for dir in /usr/local/bin/ltemod "$SELF_DIR" "$SELF_DIR/../modem" "$SELF_DIR/../wifi"; do
        [[ -f "$dir/$name" ]] && echo "$dir/$name" && return 0
    done
    return 1
}

wait_for_ip() {
    local iface="$1"
    local timeout="${2:-30}"
    local elapsed=0
    while ! ip addr show "$iface" 2>/dev/null | grep -q "inet "; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $timeout ]]; then
            return 1
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Start: LTE
# ---------------------------------------------------------------------------
start_lte() {
    log "Starting LTE uplink (${WWAN_IFACE})..."

    local script
    script=$(find_script "connect-modem.sh") || {
        log_err "connect-modem.sh not found"
        return 1
    }

    bash "$script" || { log_err "connect-modem.sh failed"; return 1; }
    echo "lte" > "$RUNTIME_DIR/uplink_mode"
    log "LTE uplink started"
}

# ---------------------------------------------------------------------------
# Start: Ethernet (другой роутер по кабелю)
# ---------------------------------------------------------------------------
start_eth() {
    log "Starting Ethernet uplink (${LAN_IFACE})..."

    if ! ip link show "$LAN_IFACE" &>/dev/null; then
        log_err "Ethernet interface $LAN_IFACE not found (check LAN_IFACE in ltemod.conf)"
        return 1
    fi

    ip link set "$LAN_IFACE" up

    # Если NM уже управляет интерфейсом и у него есть IP — готово
    if ip addr show "$LAN_IFACE" 2>/dev/null | grep -q "inet "; then
        local eth_ip
        eth_ip=$(ip addr show "$LAN_IFACE" | grep "inet " | awk '{print $2}' | head -1)
        log "Ethernet $LAN_IFACE already has IP: $eth_ip (managed by NM)"
        echo "eth" > "$RUNTIME_DIR/uplink_mode"
        return 0
    fi

    # Попробовать DHCP
    log "Requesting DHCP lease on $LAN_IFACE (timeout 30s)..."
    if command -v dhclient &>/dev/null; then
        dhclient -1 -t 30 "$LAN_IFACE" 2>/dev/null || true
    elif command -v dhcpcd &>/dev/null; then
        dhcpcd --timeout 30 "$LAN_IFACE" 2>/dev/null || true
    else
        # Попробовать через NetworkManager
        nmcli connection add type ethernet ifname "$LAN_IFACE" con-name "ltemod-eth-uplink" \
            ipv4.method auto ipv6.method ignore 2>/dev/null || true
        nmcli connection up "ltemod-eth-uplink" 2>/dev/null || true
    fi

    if wait_for_ip "$LAN_IFACE" 30; then
        local eth_ip
        eth_ip=$(ip addr show "$LAN_IFACE" | grep "inet " | awk '{print $2}' | head -1)
        log "Ethernet uplink ready: $LAN_IFACE → $eth_ip"
        echo "eth" > "$RUNTIME_DIR/uplink_mode"
    else
        log_err "No IP received on $LAN_IFACE after 30s"
        log_err "Make sure the Ethernet cable is connected to the router/modem"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Start: WiFi client (подключение к upstream WiFi роутеру)
# ---------------------------------------------------------------------------
start_wifi_client() {
    log "Starting WiFi client uplink (${WIFI_CLIENT_IFACE})..."

    if [[ -z "${WIFI_CLIENT_SSID:-}" ]]; then
        log_err "WIFI_CLIENT_SSID is not set in ltemod.conf"
        return 1
    fi

    local script
    script=$(find_script "setup-wifi-client.sh") || {
        log_err "setup-wifi-client.sh not found"
        return 1
    }

    bash "$script" connect || { log_err "WiFi client connect failed"; return 1; }

    if wait_for_ip "$WIFI_CLIENT_IFACE" 20; then
        local wc_ip
        wc_ip=$(ip addr show "$WIFI_CLIENT_IFACE" | grep "inet " | awk '{print $2}' | head -1)
        log "WiFi client uplink ready: $WIFI_CLIENT_IFACE → $wc_ip (SSID: $WIFI_CLIENT_SSID)"
        echo "wifi-client" > "$RUNTIME_DIR/uplink_mode"
    else
        log_err "No IP on $WIFI_CLIENT_IFACE after connecting to '$WIFI_CLIENT_SSID'"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Start: Auto (пробовать по UPLINK_PRIORITY)
# ---------------------------------------------------------------------------
start_auto() {
    log "Auto uplink: trying in order: ${UPLINK_PRIORITY}"
    for uplink in ${UPLINK_PRIORITY}; do
        log "Trying uplink: $uplink..."
        case "$uplink" in
            lte)                 start_lte          && return 0 ;;
            wifi|wifi-client)    start_wifi_client  && return 0 ;;
            eth|ethernet)        start_eth          && return 0 ;;
        esac
        log "Uplink '$uplink' unavailable, trying next..."
    done
    log_err "All uplink methods failed (tried: ${UPLINK_PRIORITY})"
    return 1
}

# ---------------------------------------------------------------------------
# Stop handlers
# ---------------------------------------------------------------------------
stop_lte() {
    nmcli connection down "$NM_CON_NAME" 2>/dev/null || true
    log "LTE connection stopped"
}

stop_eth() {
    # NM продолжает управлять eth0; не отключаем (иначе потеряем сам ssh/web доступ)
    log "Ethernet uplink: interface stays up (managed by NetworkManager)"
    nmcli connection down "ltemod-eth-uplink" 2>/dev/null || true
    nmcli connection delete "ltemod-eth-uplink" 2>/dev/null || true
}

stop_wifi_client() {
    local script
    script=$(find_script "setup-wifi-client.sh") && \
        bash "$script" disconnect 2>/dev/null || true
    log "WiFi client stopped"
}

do_stop() {
    local active_mode
    active_mode=$(cat "$RUNTIME_DIR/uplink_mode" 2>/dev/null || echo "$UPLINK_MODE")
    log "Stopping uplink (mode: $active_mode)..."
    case "$active_mode" in
        lte)         stop_lte ;;
        eth)         stop_eth ;;
        wifi-client) stop_wifi_client ;;
        *)           stop_lte ;;  # safe default
    esac
    rm -f "$RUNTIME_DIR/uplink_mode"
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
do_status() {
    local active_mode
    active_mode=$(cat "$RUNTIME_DIR/uplink_mode" 2>/dev/null || echo "unknown")
    local uplink_iface
    uplink_iface=$(cat "$RUNTIME_DIR/uplink_iface" 2>/dev/null || echo "unknown")
    local config_mode="$UPLINK_MODE"

    echo ""
    echo "============================="
    echo "  Uplink Status"
    echo "============================="
    echo "  Config mode:  $config_mode"
    echo "  Active mode:  $active_mode"
    echo "  Active iface: $uplink_iface"
    echo "-----------------------------"

    case "$active_mode" in
        lte)
            local lte_ip
            lte_ip=$(ip addr show "$WWAN_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
            echo "  LTE ($WWAN_IFACE): $lte_ip"
            ;;
        eth)
            local eth_ip
            eth_ip=$(ip addr show "$LAN_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
            echo "  Ethernet ($LAN_IFACE): $eth_ip"
            ;;
        wifi-client)
            local wc_ip
            wc_ip=$(ip addr show "$WIFI_CLIENT_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
            echo "  WiFi client ($WIFI_CLIENT_IFACE): $wc_ip"
            local script
            script=$(find_script "setup-wifi-client.sh") && bash "$script" status 2>/dev/null || true
            ;;
        *)
            echo "  No active uplink"
            ;;
    esac
    echo "============================="
    echo ""
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
CMD="${1:-status}"
ROUTING_SCRIPT=$(find_script "setup-routing.sh") || true

case "$CMD" in
    start)
        # $2 lets the watchdog failover to a specific mode without editing ltemod.conf.
        # Falls back to the config value when called without argument (normal boot path).
        UPLINK_MODE="${2:-$UPLINK_MODE}"
        log "=== setup-uplink start (UPLINK_MODE=${UPLINK_MODE}) ==="
        case "$UPLINK_MODE" in
            lte)               start_lte         ;;
            eth|ethernet)      start_eth         ;;
            wifi-client|wifi)  start_wifi_client ;;
            auto)              start_auto        ;;
            *)
                log_err "Unknown UPLINK_MODE='$UPLINK_MODE' (valid: lte|eth|wifi-client|auto)"
                exit 1
                ;;
        esac

        # Всегда завершать настройкой маршрутизации
        if [[ -n "${ROUTING_SCRIPT:-}" && -f "$ROUTING_SCRIPT" ]]; then
            log "Running setup-routing.sh..."
            bash "$ROUTING_SCRIPT" || log_err "setup-routing.sh failed (non-fatal)"
        else
            log_err "setup-routing.sh not found — routing not configured"
        fi
        log "=== Uplink ready (mode: $(cat "$RUNTIME_DIR/uplink_mode" 2>/dev/null)) ==="
        ;;

    stop)
        do_stop
        ;;

    restart)
        do_stop
        sleep 2
        exec "$0" start
        ;;

    status)
        do_status
        ;;

    *)
        echo "Usage: $0 {start|stop|restart|status}"
        echo "  UPLINK_MODE in /etc/ltemod/ltemod.conf:"
        echo "    lte         — LTE-модем (по умолчанию)"
        echo "    eth         — Ethernet кабель от другого роутера"
        echo "    wifi-client — Подключение к WiFi роутеру"
        echo "    auto        — Автовыбор по UPLINK_PRIORITY"
        exit 1
        ;;
esac
