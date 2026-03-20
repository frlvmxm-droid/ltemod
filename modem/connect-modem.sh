#!/bin/bash
# =============================================================================
# connect-modem.sh — подключение LTE-модема Sierra Wireless EM7565
# Поддерживает протоколы: MBIM (приоритет) и QMI (резерв)
# =============================================================================

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

log() {
    logger -t "$LOG_TAG" "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
    logger -t "$LOG_TAG" -p user.err "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# Ждать появления устройства модема
wait_for_modem_dev() {
    local dev="$1"
    local timeout=30
    local elapsed=0
    log "Waiting for modem device $dev..."
    while [[ ! -e "$dev" ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $timeout ]]; then
            log_err "Modem device $dev not found after ${timeout}s"
            return 1
        fi
    done
    log "Modem device $dev found"
    return 0
}

# Ждать появления сетевого интерфейса
wait_for_iface() {
    local iface="$1"
    local timeout=30
    local elapsed=0
    log "Waiting for network interface $iface..."
    while ! ip link show "$iface" &>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $timeout ]]; then
            log_err "Network interface $iface not found after ${timeout}s"
            return 1
        fi
    done
    log "Interface $iface is available"
    return 0
}

# Ждать получения IP адреса
wait_for_ip() {
    local iface="$1"
    local timeout=30
    local elapsed=0
    log "Waiting for IP address on $iface..."
    while ! ip addr show "$iface" | grep -q "inet "; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $timeout ]]; then
            log_err "No IP address on $iface after ${timeout}s"
            return 1
        fi
    done
    local ip
    ip=$(ip addr show "$iface" | grep "inet " | awk '{print $2}' | head -1)
    log "Interface $iface got IP: $ip"
    return 0
}

# Подключение через MBIM (NetworkManager)
connect_mbim() {
    log "Connecting via MBIM protocol using NetworkManager..."

    wait_for_modem_dev "$MODEM_DEV" || return 1

    # Дать ModemManager время инициализировать модем
    sleep 3

    # Удалить старое соединение если существует
    if nmcli connection show "$NM_CON_NAME" &>/dev/null; then
        log "Removing existing NM connection: $NM_CON_NAME"
        nmcli connection delete "$NM_CON_NAME" || true
    fi

    # Создать новое GSM/MBIM соединение
    log "Creating NM connection for APN: $APN"
    nmcli connection add \
        type gsm \
        ifname "$MODEM_DEV" \
        con-name "$NM_CON_NAME" \
        apn "$APN" \
        connection.autoconnect yes || {
        log_err "Failed to create NM connection"
        return 1
    }

    # Поднять соединение
    log "Activating NM connection..."
    nmcli connection up "$NM_CON_NAME" || {
        log_err "Failed to activate NM connection"
        return 1
    }

    # Ждать сетевой интерфейс
    wait_for_iface "$WWAN_IFACE" || return 1
    wait_for_ip "$WWAN_IFACE" || return 1

    log "MBIM connection established successfully"
    return 0
}

# Подключение через QMI (прямое, без NetworkManager)
connect_qmi() {
    log "Connecting via QMI protocol..."

    wait_for_modem_dev "$MODEM_DEV" || return 1

    # Остановить ModemManager чтобы не мешал прямому QMI доступу
    if systemctl is-active --quiet ModemManager; then
        log "Stopping ModemManager for direct QMI access..."
        systemctl stop ModemManager
    fi

    # Настройка файла qmi-network
    local qmi_conf="/etc/qmi-network.conf"
    cat > "$qmi_conf" <<EOF
APN=$APN
APN_USER=
APN_PASS=
PROXY=yes
EOF

    # Поднять интерфейс модема
    if ! ip link show "$WWAN_IFACE" &>/dev/null; then
        log_err "QMI network interface $WWAN_IFACE not found"
        log_err "Check that qmi_wwan kernel module is loaded: lsmod | grep qmi_wwan"
        return 1
    fi

    ip link set "$WWAN_IFACE" up

    # Подключиться через qmi-network
    log "Starting QMI connection..."
    qmi-network "$MODEM_DEV" start || {
        log_err "qmi-network start failed"
        return 1
    }

    # Получить IP через udhcpc или dhclient
    if command -v udhcpc &>/dev/null; then
        udhcpc -i "$WWAN_IFACE" -q -n || {
            log_err "udhcpc failed on $WWAN_IFACE"
            return 1
        }
    elif command -v dhclient &>/dev/null; then
        dhclient -v "$WWAN_IFACE" || {
            log_err "dhclient failed on $WWAN_IFACE"
            return 1
        }
    else
        log_err "No DHCP client found (install udhcpc or isc-dhcp-client)"
        return 1
    fi

    wait_for_ip "$WWAN_IFACE" || return 1

    log "QMI connection established successfully"
    return 0
}

# Определить фактический сетевой интерфейс модема
detect_wwan_iface() {
    # Попробовать стандартные имена
    for iface in wwan0 wwp0s20f0u2 wwp0s20u2 wwan1; do
        if ip link show "$iface" &>/dev/null; then
            echo "$iface"
            return 0
        fi
    done
    # Поиск через sysfs
    local found
    found=$(find /sys/class/net -name "ww*" -maxdepth 1 2>/dev/null | head -1 | xargs basename 2>/dev/null || true)
    if [[ -n "$found" ]]; then
        echo "$found"
        return 0
    fi
    return 1
}

# === Главная логика ===

log "=== Starting LTE modem connection ==="
log "Protocol: $MODEM_PROTO | Device: $MODEM_DEV | APN: $APN"

# Определить реальный интерфейс модема (если не задан явно)
if ! ip link show "$WWAN_IFACE" &>/dev/null; then
    detected=$(detect_wwan_iface || true)
    if [[ -n "$detected" ]]; then
        log "Auto-detected wwan interface: $detected (configured: $WWAN_IFACE)"
        WWAN_IFACE="$detected"
    fi
fi

# Подключиться согласно протоколу
case "$MODEM_PROTO" in
    mbim)
        if connect_mbim; then
            log "=== LTE connection UP (MBIM) ==="
            exit 0
        else
            log_err "MBIM connection failed, trying QMI fallback..."
            MODEM_PROTO="qmi"
            connect_qmi || { log_err "=== LTE connection FAILED ==="; exit 1; }
            log "=== LTE connection UP (QMI fallback) ==="
        fi
        ;;
    qmi)
        connect_qmi || { log_err "=== LTE connection FAILED ==="; exit 1; }
        log "=== LTE connection UP (QMI) ==="
        ;;
    *)
        log_err "Unknown protocol: $MODEM_PROTO (use 'mbim' or 'qmi')"
        exit 1
        ;;
esac
