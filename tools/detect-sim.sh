#!/bin/bash
# =============================================================================
# detect-sim.sh — автоопределение оператора SIM-карты и настройка APN/USSD
#
# Использование:
#   detect-sim                — показать оператора и рекомендованные настройки
#   detect-sim --write        — записать APN/USSD в /etc/ltemod/ltemod.conf
#   detect-sim --get-apn      — вывести только APN в stdout (для скриптов)
#   source detect-sim.sh      — подключить функции sim_detect и SIM_* переменные
# =============================================================================

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"

# ---------------------------------------------------------------------------
# База данных операторов (MCC+MNC → NAME:APN:APN_USER:APN_PASS:USSD)
# ---------------------------------------------------------------------------
# Поля разделены двоеточием, позиция фиксирована (cut -d: -fN).
# Пустые поля = не требуется.
declare -A _SIM_DB=(
    ["25001"]="МТС:internet.mts.ru:::*100#"
    ["25002"]="МегаФон:internet:::#100#"
    ["25020"]="Tele2:m.tele2.ru:::*100#"
    ["25035"]="Yota:yota.ru:::"
    ["25099"]="Билайн:internet.beeline.ru:beeline:beeline:*102#"
    # Региональные и резервные коды
    ["25016"]="Мотив:internet:::*105#"
    ["25039"]="Ростелеком:internet:::*105#"
    ["25028"]="Билайн (alt):internet.beeline.ru:beeline:beeline:*102#"
)

# ---------------------------------------------------------------------------
# Вспомогательные функции (доступны и при source, и при прямом запуске)
# ---------------------------------------------------------------------------

# Найти индекс модема через mmcli -L
_sim_modem_index() {
    mmcli -L 2>/dev/null \
        | grep -oE '/Modems/[0-9]+' \
        | grep -oE '[0-9]+' \
        | head -1
}

# Получить код оператора (MCC+MNC, например "25001")
# Приоритет: mmcli -K (machine-readable) → verbose grep
_sim_get_operator_code() {
    local idx="$1" code=""
    # Основной метод: машиночитаемый вывод
    code=$(mmcli -m "$idx" -K 2>/dev/null \
        | grep 'modem\.3gpp\.operator-code' \
        | awk -F': ' '{print $2}' \
        | tr -d ' ')
    # Запасной: обычный вывод (совместимость со старыми версиями mmcli)
    if [[ -z "$code" ]]; then
        code=$(mmcli -m "$idx" 2>/dev/null \
            | grep -i 'operator id\|operator-code' \
            | awk -F'[:|]' '{print $NF}' \
            | tr -d ' ')
    fi
    # Валидация: только цифры, 5-6 символов (MCC=3 + MNC=2-3)
    if [[ "$code" =~ ^[0-9]{5,6}$ ]]; then
        echo "$code"
        return 0
    fi
    return 1
}

# Получить имя оператора из mmcli (для отображения)
_sim_get_operator_name() {
    local idx="$1" name=""
    name=$(mmcli -m "$idx" -K 2>/dev/null \
        | grep 'modem\.3gpp\.operator-name' \
        | awk -F': ' '{print $2}' \
        | sed 's/^ *//')
    if [[ -z "$name" ]]; then
        name=$(mmcli -m "$idx" 2>/dev/null \
            | grep -i 'operator name' \
            | awk -F': ' '{print $NF}' \
            | sed 's/^ *//')
    fi
    echo "${name:-unknown}"
}

# Найти оператора в базе по коду
_sim_lookup() {
    local code="$1"
    local record="${_SIM_DB[$code]:-}"
    if [[ -n "$record" ]]; then
        echo "$record"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Главная функция детекции — вызывается напрямую или через source
# Устанавливает переменные: SIM_OPERATOR_CODE, SIM_OPERATOR_NAME,
#                            SIM_APN, SIM_APN_USER, SIM_APN_PASS, SIM_USSD
# Возвращает 0 при успехе, 1 при любой ошибке (не вызывает exit)
# ---------------------------------------------------------------------------
sim_detect() {
    local idx code record
    _warn() { echo "WARNING: detect-sim: $*" >&2; }

    if ! command -v mmcli &>/dev/null; then
        _warn "mmcli not available (ModemManager not installed)"
        return 1
    fi

    idx=$(_sim_modem_index)
    if [[ -z "$idx" ]]; then
        _warn "no modem detected by ModemManager (mmcli -L)"
        return 1
    fi

    code=$(_sim_get_operator_code "$idx") || {
        _warn "modem not registered on network (no operator code yet)"
        return 1
    }

    record=$(_sim_lookup "$code") || {
        _warn "unknown operator code: $code — add to _SIM_DB in detect-sim.sh"
        return 1
    }

    SIM_OPERATOR_CODE="$code"
    SIM_OPERATOR_NAME=$(_sim_get_operator_name "$idx")
    SIM_APN=$(echo      "$record" | cut -d: -f2)
    SIM_APN_USER=$(echo "$record" | cut -d: -f3)
    SIM_APN_PASS=$(echo "$record" | cut -d: -f4)
    SIM_USSD=$(echo     "$record" | cut -d: -f5)
    return 0
}

# ---------------------------------------------------------------------------
# CLI — выполняется только при прямом запуске, не при source
# ---------------------------------------------------------------------------
(return 0 2>/dev/null) && _SOURCED=1 || _SOURCED=0

if [[ "$_SOURCED" == "0" ]]; then
    set -uo pipefail

    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
    ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
    fail() { echo -e "  ${RED}✗${NC} $*"; }
    info() { echo -e "  ${YELLOW}→${NC} $*"; }

    # _set — обновить ключ в ltemod.conf через sed (аналогично detect-hardware.sh)
    _set() {
        local k="$1" v="$2"
        [[ -z "$v" ]] && return 0
        if grep -qE "^${k}=" "$CONFIG_FILE"; then
            sed -i -E "s|^(${k}=).*|\1\"${v}\"|" "$CONFIG_FILE"
            ok "Set ${k}=\"${v}\""
        fi
    }

    MODE="${1:-}"

    if ! command -v mmcli &>/dev/null; then
        if [[ "$MODE" == "--get-apn" ]]; then
            echo ""
            exit 0
        fi
        fail "mmcli (ModemManager) не найден — установи: apt install modemmanager"
        exit 1
    fi

    if ! sim_detect; then
        if [[ "$MODE" == "--get-apn" ]]; then
            echo ""
            exit 0
        fi
        # sim_detect уже напечатал предупреждение в stderr
        exit 1
    fi

    case "$MODE" in
        --get-apn)
            echo "$SIM_APN"
            exit 0
            ;;
        --write)
            if [[ $EUID -ne 0 ]]; then
                fail "Запусти с sudo для записи в $CONFIG_FILE"
                exit 1
            fi
            if [[ ! -f "$CONFIG_FILE" ]]; then
                fail "Config не найден: $CONFIG_FILE"
                exit 1
            fi
            echo -e "${CYAN}=== Запись настроек SIM в $CONFIG_FILE ===${NC}"
            _set APN                "$SIM_APN"
            _set APN_USER           "$SIM_APN_USER"
            _set APN_PASS           "$SIM_APN_PASS"
            _set USSD_BALANCE_CODE  "$SIM_USSD"
            echo ""
            info "Проверь: cat $CONFIG_FILE"
            ;;
        *)
            echo -e "${CYAN}=== Определение SIM-карты ===${NC}"
            ok  "Код оператора : $SIM_OPERATOR_CODE"
            ok  "Оператор      : $SIM_OPERATOR_NAME"
            echo ""
            info "Рекомендованные настройки:"
            info "  APN               = $SIM_APN"
            [[ -n "${SIM_APN_USER:-}" ]] && info "  APN_USER          = $SIM_APN_USER"
            [[ -n "${SIM_APN_PASS:-}" ]] && info "  APN_PASS          = $SIM_APN_PASS"
            [[ -n "${SIM_USSD:-}"     ]] && info "  USSD_BALANCE_CODE = $SIM_USSD"
            echo ""
            info "Записать в конфиг: sudo detect-sim --write"
            ;;
    esac
fi
