#!/bin/bash
# =============================================================================
# data-usage.sh — учёт трафика LTE-модема
#
# Для мобильной SIM с лимитами: сколько данных съедено за день/месяц.
# Использует vnstat (если установлен), иначе — счётчики ядра из /sys.
#
# Использование:
#   data-usage            — сводка (сегодня / месяц / всего)
#   data-usage live       — трафик в реальном времени (vnstat -l)
#   data-usage month      — по месяцам
#   data-usage day        — по дням
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

WWAN_IFACE="${WWAN_IFACE:-wwan0}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
info() { echo -e "  ${YELLOW}→${NC} $*"; }

# Человекочитаемый размер из байт
human() {
    local b="${1:-0}"
    if   (( b >= 1073741824 )); then awk "BEGIN{printf \"%.2f GiB\", $b/1073741824}"
    elif (( b >= 1048576 ));    then awk "BEGIN{printf \"%.2f MiB\", $b/1048576}"
    elif (( b >= 1024 ));       then awk "BEGIN{printf \"%.2f KiB\", $b/1024}"
    else echo "${b} B"; fi
}

if ! ip link show "$WWAN_IFACE" &>/dev/null; then
    fail "LTE interface $WWAN_IFACE not found"
    exit 1
fi

HAVE_VNSTAT=0
command -v vnstat &>/dev/null && HAVE_VNSTAT=1

case "${1:-summary}" in
    live)
        if [[ $HAVE_VNSTAT -eq 1 ]]; then
            exec vnstat -l -i "$WWAN_IFACE"
        else
            fail "vnstat not installed (нужен для live-режима). Установите: sudo apt install vnstat"
            exit 1
        fi
        ;;
    month|months)
        [[ $HAVE_VNSTAT -eq 1 ]] && exec vnstat -m -i "$WWAN_IFACE"
        fail "vnstat not installed"; exit 1
        ;;
    day|days)
        [[ $HAVE_VNSTAT -eq 1 ]] && exec vnstat -d -i "$WWAN_IFACE"
        fail "vnstat not installed"; exit 1
        ;;
    summary|"")
        echo -e "${CYAN}=== LTE data usage ($WWAN_IFACE) ===${NC}"
        if [[ $HAVE_VNSTAT -eq 1 ]]; then
            vnstat -i "$WWAN_IFACE" 2>/dev/null || info "vnstat ещё не накопил данные (нужно немного подождать)"
        else
            info "vnstat не установлен — показываю счётчики с момента поднятия интерфейса:"
            rx=$(cat "/sys/class/net/$WWAN_IFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
            tx=$(cat "/sys/class/net/$WWAN_IFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
            ok "Получено (RX): $(human "$rx")"
            ok "Отправлено (TX): $(human "$tx")"
            ok "Всего: $(human $(( rx + tx )))"
            echo ""
            info "Для истории по дням/месяцам установите vnstat: sudo apt install vnstat"
            info "и зарегистрируйте интерфейс: sudo vnstat -i $WWAN_IFACE"
        fi
        ;;
    *)
        echo "Usage: $0 {summary|live|month|day}"
        exit 1
        ;;
esac
