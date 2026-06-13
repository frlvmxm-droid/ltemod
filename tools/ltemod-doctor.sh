#!/bin/bash
# =============================================================================
# ltemod-doctor.sh — диагностика конфигурации и окружения ltemod
#
# Проверяет конфиг и систему ДО запуска, чтобы поймать ошибки заранее,
# а не словить их в runtime.
#
# Использование:
#   ltemod-doctor             — полная проверка (вывод + код возврата)
#   ltemod-doctor --preflight — только критичные для запуска WiFi AP проверки
#                               (тихо при успехе; для ExecStartPre=)
#
# Код возврата: 0 — критичных проблем нет, 1 — есть (FAIL).
# Предупреждения (WARN) код возврата не меняют.
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Значения по умолчанию
WWAN_IFACE="${WWAN_IFACE:-wwan0}"
LAN_IFACE="${LAN_IFACE:-end0}"
WIFI_AP_ENABLED="${WIFI_AP_ENABLED:-yes}"
WIFI_AP_IFACE="${WIFI_AP_IFACE:-wlan0}"
WIFI_AP_SSID="${WIFI_AP_SSID:-OrangePi-Router}"
WIFI_AP_PASSWORD="${WIFI_AP_PASSWORD:-}"
WIFI_AP_BAND="${WIFI_AP_BAND:-2g}"
WIFI_AP_CHANNEL_2G="${WIFI_AP_CHANNEL_2G:-6}"
WIFI_AP_CHANNEL_5G="${WIFI_AP_CHANNEL_5G:-36}"
WIFI_AP_IP="${WIFI_AP_IP:-192.168.10.1}"
WIFI_AP_DHCP_RANGE="${WIFI_AP_DHCP_RANGE:-}"
BRIDGE_LAN_ENABLED="${BRIDGE_LAN_ENABLED:-no}"
WIFI_CLIENT_ENABLED="${WIFI_CLIENT_ENABLED:-no}"
VPN_PROTO="${VPN_PROTO:-none}"
WG_CONFIG="${WG_CONFIG:-/etc/wireguard/wg0.conf}"
AMNEZIA_CONFIG="${AMNEZIA_CONFIG:-/etc/amnezia/amneziawg/awg0.conf}"
VLESS_CONFIG="${VLESS_CONFIG:-/etc/sing-box/config.json}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

PREFLIGHT=0
[[ "${1:-}" == "--preflight" ]] && PREFLIGHT=1

FAILS=0
WARNS=0

ok()      { [[ $PREFLIGHT -eq 1 ]] && return 0; echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { WARNS=$((WARNS+1)); echo -e "  ${YELLOW}⚠${NC} $*"; }
fail()    { FAILS=$((FAILS+1)); echo -e "  ${RED}✗${NC} $*"; }
section() { [[ $PREFLIGHT -eq 1 ]] && return 0; echo ""; echo -e "${CYAN}[ $* ]${NC}"; }

# Подключить детектор железа (если установлен рядом или в /usr/local/bin/ltemod)
for det in "$(dirname "$0")/detect-hardware.sh" \
           "/usr/local/bin/ltemod/detect-hardware.sh"; do
    if [[ -f "$det" ]]; then
        # shellcheck disable=SC1090
        source "$det" 2>/dev/null && break
    fi
done

iface_exists() { ip link show "$1" &>/dev/null; }

# Канал валиден для диапазона
channel_valid() {
    local band="$1" ch="$2"
    [[ "$ch" =~ ^[0-9]+$ ]] || return 1
    if [[ "$band" == "2g" ]]; then
        (( ch >= 1 && ch <= 13 ))
    else
        local valid=" 36 40 44 48 52 56 60 64 100 104 108 112 116 120 124 128 132 136 140 144 149 153 157 161 165 "
        [[ "$valid" == *" $ch "* ]]
    fi
}

# Первые три октета IPv4 (подсеть /24)
net24() { echo "$1" | cut -d. -f1-3; }

if [[ $PREFLIGHT -eq 0 ]]; then
    echo "============================================"
    echo -e "  ${CYAN}ltemod doctor — health check${NC}"
    echo "============================================"
fi

# ---------------------------------------------------------------------------
# 1. Конфиг
# ---------------------------------------------------------------------------
section "Configuration file"
if [[ -f "$CONFIG_FILE" ]]; then
    ok "Config found: $CONFIG_FILE"
else
    fail "Config NOT found: $CONFIG_FILE (run install.sh)"
fi

# ---------------------------------------------------------------------------
# 2. WiFi AP — критичные проверки (часть исполняется и в --preflight)
# ---------------------------------------------------------------------------
section "WiFi Access Point"
if [[ "$WIFI_AP_ENABLED" == "yes" ]]; then
    # Интерфейс существует
    if iface_exists "$WIFI_AP_IFACE"; then
        ok "WiFi interface $WIFI_AP_IFACE exists"
    else
        fail "WiFi interface $WIFI_AP_IFACE NOT found (check WIFI_AP_IFACE; run detect-hardware.sh)"
    fi

    # Поддержка AP-режима драйвером
    if declare -f wifi_supports_ap &>/dev/null && iface_exists "$WIFI_AP_IFACE"; then
        if wifi_supports_ap "$WIFI_AP_IFACE"; then
            ok "Driver supports AP mode on $WIFI_AP_IFACE"
        else
            rc=$?
            [[ $rc -eq 2 ]] && warn "Cannot verify AP mode (install 'iw')" \
                            || fail "Driver does NOT support AP mode on $WIFI_AP_IFACE"
        fi
    fi

    # Длина пароля WPA: 8..63
    plen=${#WIFI_AP_PASSWORD}
    if (( plen >= 8 && plen <= 63 )); then
        ok "WiFi password length OK ($plen chars)"
    else
        fail "WiFi password must be 8..63 chars (now: $plen) — hostapd will refuse to start"
    fi

    # Канал валиден
    if [[ "$WIFI_AP_BAND" == "5g" || "$WIFI_AP_BAND" == "both" ]]; then
        channel_valid 5g "$WIFI_AP_CHANNEL_5G" \
            && ok "5GHz channel $WIFI_AP_CHANNEL_5G valid" \
            || fail "5GHz channel '$WIFI_AP_CHANNEL_5G' invalid"
    fi
    if [[ "$WIFI_AP_BAND" == "2g" || "$WIFI_AP_BAND" == "both" ]]; then
        channel_valid 2g "$WIFI_AP_CHANNEL_2G" \
            && ok "2.4GHz channel $WIFI_AP_CHANNEL_2G valid" \
            || fail "2.4GHz channel '$WIFI_AP_CHANNEL_2G' invalid (use 1..13)"
    fi

    # rfkill: WiFi не должен быть soft-blocked
    if command -v rfkill &>/dev/null; then
        if rfkill list 2>/dev/null | grep -A2 -i wireless | grep -qi "Soft blocked: yes"; then
            warn "WiFi is soft-blocked (run: rfkill unblock wifi)"
        fi
    fi
else
    ok "WiFi AP disabled (WIFI_AP_ENABLED=no) — skipping AP checks"
fi

# В режиме preflight на этом проверки заканчиваются
if [[ $PREFLIGHT -eq 1 ]]; then
    exit $(( FAILS > 0 ? 1 : 0 ))
fi

# ---------------------------------------------------------------------------
# 3. Сетевые интерфейсы и подсети
# ---------------------------------------------------------------------------
section "Network interfaces & subnets"
if iface_exists "$LAN_IFACE"; then
    ok "LAN interface $LAN_IFACE exists"
else
    warn "LAN interface $LAN_IFACE not found (check LAN_IFACE; run detect-hardware.sh)"
fi

# Пересечение AP-подсети с DHCP-диапазоном / шлюзом
if [[ "$WIFI_AP_ENABLED" == "yes" && -n "$WIFI_AP_DHCP_RANGE" ]]; then
    ap_net=$(net24 "$WIFI_AP_IP")
    dhcp_start=$(echo "$WIFI_AP_DHCP_RANGE" | cut -d, -f1)
    dhcp_net=$(net24 "$dhcp_start")
    if [[ "$ap_net" == "$dhcp_net" ]]; then
        ok "AP IP $WIFI_AP_IP and DHCP range in same /24 ($ap_net.0/24)"
    else
        fail "AP IP ($ap_net.0/24) and DHCP range ($dhcp_net.0/24) are in DIFFERENT subnets"
    fi
    # Шлюз не должен попадать в DHCP-пул
    gw_octet=$(echo "$WIFI_AP_IP" | cut -d. -f4)
    start_octet=$(echo "$dhcp_start" | cut -d. -f4)
    end_octet=$(echo "$WIFI_AP_DHCP_RANGE" | cut -d, -f2 | cut -d. -f4)
    if [[ "$gw_octet" =~ ^[0-9]+$ && "$start_octet" =~ ^[0-9]+$ && "$end_octet" =~ ^[0-9]+$ ]]; then
        if (( gw_octet >= start_octet && gw_octet <= end_octet )); then
            warn "Gateway $WIFI_AP_IP falls INSIDE DHCP pool — может конфликтовать с клиентом"
        fi
    fi
fi

# LAN со статическим IP в той же /24, что AP (не-bridge режим) → конфликт
if [[ "$WIFI_AP_ENABLED" == "yes" && "$BRIDGE_LAN_ENABLED" != "yes" ]] && iface_exists "$LAN_IFACE"; then
    lan_ip=$(ip -4 addr show "$LAN_IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    if [[ -n "$lan_ip" && "$(net24 "$lan_ip")" == "$(net24 "$WIFI_AP_IP")" ]]; then
        warn "LAN $LAN_IFACE ($lan_ip) и AP в одной /24 — возможен конфликт маршрутов"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Зависимости (бинарники)
# ---------------------------------------------------------------------------
section "Dependencies"
need_bin() {  # need_bin BIN [optional]
    local bin="$1" opt="${2:-}"
    if command -v "$bin" &>/dev/null; then
        ok "$bin"
    elif [[ "$opt" == "optional" ]]; then
        warn "$bin not installed (нужен только для соответствующей функции)"
    else
        fail "$bin not installed (run install.sh)"
    fi
}
need_bin hostapd
need_bin dnsmasq
need_bin iptables
need_bin iw
need_bin wg-quick optional
need_bin awg-quick optional
need_bin sing-box optional
need_bin mmcli optional

# ---------------------------------------------------------------------------
# 5. Конфликтующие службы
# ---------------------------------------------------------------------------
section "Conflicting services"
if systemctl is-enabled --quiet hostapd.service 2>/dev/null; then
    warn "Системный hostapd.service включён — должен управляться wifi-ap.service. Отключите: sudo systemctl disable --now hostapd"
else
    ok "System hostapd.service not enabled (good)"
fi

# ---------------------------------------------------------------------------
# 6. VPN-конфиг для выбранного протокола
# ---------------------------------------------------------------------------
section "VPN configuration"
case "$VPN_PROTO" in
    wg)
        [[ -f "$WG_CONFIG" ]] && ok "WireGuard config: $WG_CONFIG" \
                              || warn "WireGuard config not found: $WG_CONFIG (run setup-vpn)"
        ;;
    amnezia)
        [[ -f "$AMNEZIA_CONFIG" ]] && ok "AmneziaWG config: $AMNEZIA_CONFIG" \
                                   || warn "AmneziaWG config not found: $AMNEZIA_CONFIG (run setup-amnezia)"
        ;;
    vless)
        [[ -f "$VLESS_CONFIG" ]] && ok "VLESS config: $VLESS_CONFIG" \
                                 || warn "VLESS config not found: $VLESS_CONFIG (run setup-vless)"
        ;;
    none|"")
        ok "No VPN selected (VPN_PROTO=none)"
        ;;
    *)
        warn "Unknown VPN_PROTO='$VPN_PROTO' (use: wg|amnezia|vless|none)"
        ;;
esac

# ---------------------------------------------------------------------------
# 7. IP forwarding
# ---------------------------------------------------------------------------
section "Routing prerequisites"
fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
[[ "$fwd" == "1" ]] && ok "IP forwarding enabled" \
                    || warn "IP forwarding disabled (включится через setup-routing/sysctl)"

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
if (( FAILS == 0 && WARNS == 0 )); then
    echo -e "  ${GREEN}All checks passed.${NC}"
elif (( FAILS == 0 )); then
    echo -e "  ${YELLOW}OK with ${WARNS} warning(s).${NC} Можно запускать."
else
    echo -e "  ${RED}${FAILS} error(s)${NC}, ${YELLOW}${WARNS} warning(s)${NC}. Исправьте ошибки перед запуском."
fi
echo "============================================"

exit $(( FAILS > 0 ? 1 : 0 ))
