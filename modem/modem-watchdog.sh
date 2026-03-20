#!/bin/bash
# =============================================================================
# modem-watchdog.sh — мониторинг LTE соединения и автопереподключение
# Запускается по таймеру: lte-watchdog.timer (каждые 60 сек)
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
VPN_IFACE="${VPN_IFACE:-wg0}"
LOG_TAG="${LOG_TAG:-ltemod}"
NM_CON_NAME="${NM_CON_NAME:-lte-connection}"

log() {
    logger -t "${LOG_TAG}-watchdog" "$*"
}

log_err() {
    logger -t "${LOG_TAG}-watchdog" -p user.err "$*"
}

# Создать runtime директорию если нет
mkdir -p "$RUNTIME_DIR"

# Читать/записать счётчик попыток
get_counter() {
    if [[ -f "$RECONNECT_COUNTER_FILE" ]]; then
        cat "$RECONNECT_COUNTER_FILE"
    else
        echo "0"
    fi
}

set_counter() {
    echo "$1" > "$RECONNECT_COUNTER_FILE"
}

reset_counter() {
    set_counter 0
}

# Проверить активный режим
get_mode() {
    if [[ -f "$MODE_FILE" ]]; then
        cat "$MODE_FILE"
    else
        echo "direct"
    fi
}

# Проверить LTE интерфейс
check_lte_iface() {
    if ! ip link show "$WWAN_IFACE" &>/dev/null; then
        return 1
    fi
    if ! ip addr show "$WWAN_IFACE" | grep -q "inet "; then
        return 1
    fi
    return 0
}

# Проверить VPN интерфейс
check_vpn_iface() {
    if ! ip link show "$VPN_IFACE" &>/dev/null; then
        return 1
    fi
    return 0
}

# Проверить интернет-соединение (3 попытки)
check_internet() {
    local attempts=3
    local i
    for (( i=1; i<=attempts; i++ )); do
        if ping -c 1 -W 5 "$PING_HOST" &>/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# Переподключить LTE-модем
reconnect_lte() {
    log "Attempting LTE reconnection..."

    # Попробовать через NetworkManager
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

    # Полное переподключение через connect-modem.sh
    local connect_script="/usr/local/bin/ltemod/connect-modem.sh"
    if [[ ! -f "$connect_script" ]]; then
        connect_script="$(dirname "$0")/connect-modem.sh"
    fi

    if [[ -f "$connect_script" ]]; then
        bash "$connect_script" && {
            log "Full reconnection successful"
            return 0
        }
        log_err "Full reconnection failed"
    else
        log_err "connect-modem.sh not found at $connect_script"
    fi

    return 1
}

# Восстановить VPN если был активен
reconnect_vpn() {
    local mode
    mode=$(get_mode)
    if [[ "$mode" == "vpn" ]]; then
        log "VPN mode active, re-enabling WireGuard..."
        local toggle_script="/usr/local/bin/ltemod/vpn-toggle.sh"
        if [[ -f "$toggle_script" ]]; then
            bash "$toggle_script" on || log_err "Failed to re-enable VPN"
        fi
    fi
}

# === Главная логика ===

log "Watchdog check started"

# Проверить LTE интерфейс
lte_ok=true
if ! check_lte_iface; then
    lte_ok=false
    log_err "LTE interface $WWAN_IFACE is DOWN or has no IP"
fi

# Проверить режим VPN
mode=$(get_mode)
if [[ "$mode" == "vpn" ]]; then
    if ! check_vpn_iface; then
        log_err "VPN interface $VPN_IFACE is DOWN while VPN mode is active"
    fi
fi

# Проверить интернет
if $lte_ok && check_internet; then
    log "Connectivity OK (ping $PING_HOST successful)"
    reset_counter
    log "Watchdog check passed"
    exit 0
fi

# Интернет не работает — пробуем переподключиться
counter=$(get_counter)
counter=$((counter + 1))
set_counter "$counter"

log_err "Connectivity FAILED (attempt $counter/$MAX_RECONNECT_ATTEMPTS)"

if [[ $counter -ge $MAX_RECONNECT_ATTEMPTS ]]; then
    log_err "Max reconnection attempts ($MAX_RECONNECT_ATTEMPTS) reached!"
    log_err "Rebooting system to recover..."
    # Дать время записать лог
    sleep 2
    /sbin/reboot
    exit 1
fi

# Попытка переподключения
if reconnect_lte; then
    sleep 5
    # Восстановить VPN если нужно
    reconnect_vpn
    sleep 5
    # Финальная проверка
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
