#!/bin/bash
# =============================================================================
# detect-hardware.sh — автоопределение сетевого железа
#
# Определяет:
#   - LAN (Ethernet) интерфейс
#   - WiFi интерфейс и поддержку AP-режима
#   - WWAN (LTE-модем) интерфейс
#
# Использование:
#   detect-hardware.sh                 — показать найденное железо
#   detect-hardware.sh --write         — записать найденное в ltemod.conf
#   source detect-hardware.sh          — подключить функции в другой скрипт
# =============================================================================

# При подключении через source функции просто становятся доступны.
# При прямом запуске — выполняется CLI-логика в конце файла.

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"

# ---------------------------------------------------------------------------
# Вспомогательные предикаты
# ---------------------------------------------------------------------------

# Является ли интерфейс беспроводным
_is_wireless() {
    local iface="$1"
    [[ -d "/sys/class/net/$iface/wireless" || -L "/sys/class/net/$iface/phy80211" ]]
}

# Физический ли интерфейс (есть устройство, не виртуальный)
_is_physical() {
    [[ -e "/sys/class/net/$1/device" ]]
}

# phy-имя для WiFi интерфейса (phy0, phy1, ...)
iface_to_phy() {
    local iface="$1"
    if [[ -L "/sys/class/net/$iface/phy80211" ]]; then
        basename "$(readlink -f "/sys/class/net/$iface/phy80211")"
    fi
}

# Поддерживает ли WiFi интерфейс AP-режим
# Коды возврата: 0 = да, 1 = нет, 2 = не удалось определить (нет iw / phy)
wifi_supports_ap() {
    local iface="$1" phy
    command -v iw &>/dev/null || return 2
    phy=$(iface_to_phy "$iface")
    [[ -z "$phy" ]] && return 2
    if iw phy "$phy" info 2>/dev/null \
        | sed -n '/Supported interface modes/,/^\t[A-Za-z]/p' \
        | grep -qE '^[[:space:]]*\*[[:space:]]*AP$'; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Детекторы интерфейсов
# ---------------------------------------------------------------------------

# LAN (Ethernet). Предпочитает порт с активным линком (carrier=1).
detect_lan_iface() {
    local first="" carrier_up="" iface type
    for d in /sys/class/net/*; do
        [[ -e "$d" ]] || continue
        iface=$(basename "$d")
        case "$iface" in
            lo|wlan*|wwan*|ww*|wg*|awg*|tun*|br*|docker*|veth*|virbr*|p2p*) continue ;;
        esac
        _is_physical "$iface" || continue
        _is_wireless "$iface" && continue
        type=$(cat "$d/type" 2>/dev/null || echo "")
        [[ "$type" == "1" ]] || continue           # ARPHRD_ETHER
        [[ -z "$first" ]] && first="$iface"
        if [[ "$(cat "$d/carrier" 2>/dev/null || echo 0)" == "1" && -z "$carrier_up" ]]; then
            carrier_up="$iface"
        fi
    done
    if [[ -n "$carrier_up" ]]; then echo "$carrier_up"; return 0; fi
    if [[ -n "$first" ]]; then echo "$first"; return 0; fi
    return 1
}

# WiFi интерфейс. Предпочитает тот, что поддерживает AP-режим.
detect_wifi_iface() {
    local first="" ap_capable="" iface
    for d in /sys/class/net/*; do
        [[ -e "$d" ]] || continue
        iface=$(basename "$d")
        _is_wireless "$iface" || continue
        # пропустить виртуальные клиентские/p2p интерфейсы
        case "$iface" in p2p*|wlan*_5g) continue ;; esac
        [[ -z "$first" ]] && first="$iface"
        if [[ -z "$ap_capable" ]] && wifi_supports_ap "$iface"; then
            ap_capable="$iface"
        fi
    done
    if [[ -n "$ap_capable" ]]; then echo "$ap_capable"; return 0; fi
    if [[ -n "$first" ]]; then echo "$first"; return 0; fi
    return 1
}

# WWAN (LTE-модем) интерфейс
detect_wwan_iface() {
    local iface
    for d in /sys/class/net/*; do
        [[ -e "$d" ]] || continue
        iface=$(basename "$d")
        case "$iface" in wwan*|wwp*) echo "$iface"; return 0 ;; esac
    done
    # запасной вариант: по DEVTYPE=wwan в uevent
    for d in /sys/class/net/*; do
        [[ -e "$d/uevent" ]] || continue
        if grep -q "DEVTYPE=wwan" "$d/uevent" 2>/dev/null; then
            basename "$d"; return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# CLI — выполняется только при прямом запуске, не при source
# ---------------------------------------------------------------------------
# (определяем, был ли скрипт запущен напрямую)
(return 0 2>/dev/null) && _SOURCED=1 || _SOURCED=0

if [[ "$_SOURCED" == "0" ]]; then
    set -uo pipefail

    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
    ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
    fail() { echo -e "  ${RED}✗${NC} $*"; }
    info() { echo -e "  ${YELLOW}→${NC} $*"; }

    lan=$(detect_lan_iface || echo "")
    wifi=$(detect_wifi_iface || echo "")
    wwan=$(detect_wwan_iface || echo "")

    echo -e "${CYAN}=== Detected hardware ===${NC}"

    if [[ -n "$lan" ]]; then ok "LAN (Ethernet):  $lan"; else fail "LAN (Ethernet):  not found"; fi

    if [[ -n "$wifi" ]]; then
        if wifi_supports_ap "$wifi"; then
            ok "WiFi interface: $wifi (AP mode: supported)"
        else
            rc=$?
            if [[ $rc -eq 2 ]]; then
                info "WiFi interface: $wifi (AP mode: unknown — install 'iw' to verify)"
            else
                fail "WiFi interface: $wifi (AP mode: NOT supported by driver)"
            fi
        fi
    else
        fail "WiFi interface: not found"
    fi

    if [[ -n "$wwan" ]]; then ok "WWAN (LTE):     $wwan"; else info "WWAN (LTE):     not found (modem may be disconnected)"; fi

    if [[ "${1:-}" == "--write" ]]; then
        echo ""
        if [[ $EUID -ne 0 ]]; then
            fail "Run with sudo to write to $CONFIG_FILE"
            exit 1
        fi
        if [[ ! -f "$CONFIG_FILE" ]]; then
            fail "Config not found: $CONFIG_FILE"
            exit 1
        fi
        _set() {  # _set KEY VALUE
            local k="$1" v="$2"
            [[ -z "$v" ]] && return 0
            if grep -qE "^${k}=" "$CONFIG_FILE"; then
                sed -i -E "s|^(${k}=).*|\1\"${v}\"|" "$CONFIG_FILE"
                ok "Set ${k}=\"${v}\""
            fi
        }
        echo -e "${CYAN}=== Writing to $CONFIG_FILE ===${NC}"
        _set LAN_IFACE "$lan"
        _set WIFI_AP_IFACE "$wifi"
        _set WWAN_IFACE "$wwan"
        echo ""
        info "Review with: cat $CONFIG_FILE"
    else
        echo ""
        info "Apply to config: sudo $0 --write"
    fi
fi
