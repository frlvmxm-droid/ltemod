#!/bin/bash
# =============================================================================
# sms.sh — SMS и USSD через LTE-модем (ModemManager / mmcli)
#
# Использование:
#   sms balance              — запросить баланс (USSD_BALANCE_CODE)
#   sms ussd <code>          — произвольный USSD-запрос (например '*100#')
#   sms list                 — список входящих SMS
#   sms read <id>            — прочитать SMS по номеру
#   sms send <number> <text> — отправить SMS
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

USSD_BALANCE_CODE="${USSD_BALANCE_CODE:-*100#}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
info() { echo -e "  ${YELLOW}→${NC} $*"; }
err()  { echo -e "${RED}ERROR:${NC} $*" >&2; }

if ! command -v mmcli &>/dev/null; then
    err "mmcli (ModemManager) not found. Install: sudo apt install modemmanager"
    exit 1
fi

# Индекс модема
modem_index() {
    mmcli -L 2>/dev/null | grep -oE '/Modems/[0-9]+' | grep -oE '[0-9]+' | head -1
}

MODEM=$(modem_index)
if [[ -z "$MODEM" ]]; then
    err "No modem detected by ModemManager (mmcli -L). Проверьте: sudo mmcli -L"
    exit 1
fi

cmd_ussd() {
    local code="${1:-}"
    [[ -z "$code" ]] && { err "Usage: $0 ussd <code>"; exit 1; }
    info "USSD request: $code (modem $MODEM)..."
    local resp
    resp=$(mmcli -m "$MODEM" --3gpp-ussd-initiate="$code" 2>&1) || {
        err "USSD failed: $resp"
        info "Возможно нужно: sudo mmcli -m $MODEM --3gpp-ussd-cancel"
        exit 1
    }
    echo "$resp" | grep -iE "response|reply" || echo "$resp"
}

cmd_balance() {
    info "Balance request via $USSD_BALANCE_CODE"
    cmd_ussd "$USSD_BALANCE_CODE"
}

cmd_list() {
    echo -e "${CYAN}=== SMS messages (modem $MODEM) ===${NC}"
    mmcli -m "$MODEM" --messaging-list-sms 2>/dev/null || info "No SMS or messaging not supported"
}

cmd_read() {
    local id="${1:-}"
    [[ -z "$id" ]] && { err "Usage: $0 read <sms-id>"; exit 1; }
    mmcli -s "$id" 2>/dev/null || { err "SMS $id not found"; exit 1; }
}

cmd_send() {
    local number="${1:-}" text="${2:-}"
    if [[ -z "$number" || -z "$text" ]]; then
        err "Usage: $0 send <number> <text>"; exit 1
    fi
    info "Creating SMS to $number..."
    local out sms_path
    out=$(mmcli -m "$MODEM" --messaging-create-sms="number=$number,text=$text" 2>&1) || {
        err "Failed to create SMS: $out"; exit 1
    }
    sms_path=$(echo "$out" | grep -oE '/SMS/[0-9]+' | head -1)
    [[ -z "$sms_path" ]] && { err "Could not parse SMS path from: $out"; exit 1; }
    if mmcli -s "$sms_path" --send 2>/dev/null; then
        ok "SMS sent to $number"
    else
        err "Failed to send SMS"; exit 1
    fi
}

case "${1:-balance}" in
    balance)    cmd_balance ;;
    ussd)       shift; cmd_ussd "${1:-}" ;;
    list|ls)    cmd_list ;;
    read)       shift; cmd_read "${1:-}" ;;
    send)       shift; cmd_send "${1:-}" "${2:-}" ;;
    *)
        echo "Usage: $0 {balance|ussd <code>|list|read <id>|send <number> <text>}"
        exit 1
        ;;
esac
