#!/bin/bash
# =============================================================================
# killswitch.sh — защита от утечки трафика мимо VPN (kill-switch + DNS)
#
# Идея: трафик КЛИЕНТОВ (LAN/WiFi/bridge) форвардится только через VPN-интерфейс.
# Если туннель падает, пакеты клиентов попытаются уйти через uplink и будут
# отброшены (DROP) — утечки в обход VPN не происходит.
# Зашифрованные пакеты самого туннеля идут из OUTPUT хоста (а не FORWARD),
# поэтому handshake к VPN-серверу продолжает работать.
#
# Дополнительно (VPN_DNS_REDIRECT=yes): DNS-запросы клиентов (порт 53)
# перенаправляются на роутер (dnsmasq → через туннель) — защита от DNS-leak.
#
# Использование:
#   killswitch on <vpn_iface> <uplink>   — включить защиту
#   killswitch off                       — выключить
#   killswitch status                    — показать состояние
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

LAN_IFACE="${LAN_IFACE:-end0}"
WIFI_AP_IFACE="${WIFI_AP_IFACE:-wlan0}"
WIFI_AP_ENABLED="${WIFI_AP_ENABLED:-yes}"
WIFI_AP_IP="${WIFI_AP_IP:-192.168.10.1}"
BRIDGE_LAN_ENABLED="${BRIDGE_LAN_ENABLED:-no}"
BRIDGE_IFACE="${BRIDGE_IFACE:-br0}"
VPN_DNS_REDIRECT="${VPN_DNS_REDIRECT:-yes}"
LOG_TAG="${LOG_TAG:-ltemod}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { logger -t "${LOG_TAG}-killswitch" "$*"; echo -e "${CYAN}[killswitch]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
info() { echo -e "  ${YELLOW}→${NC} $*"; }

if [[ $EUID -ne 0 && "${1:-}" != "status" ]]; then
    echo "ERROR: requires root" >&2; exit 1
fi

# Список клиентских интерфейсов (откуда форвардится трафик пользователей)
client_ifaces() {
    if [[ "$BRIDGE_LAN_ENABLED" == "yes" && "$WIFI_AP_ENABLED" == "yes" ]]; then
        echo "$BRIDGE_IFACE"
    else
        echo "$LAN_IFACE"
        [[ "$WIFI_AP_ENABLED" == "yes" ]] && echo "$WIFI_AP_IFACE"
    fi
}

ks_on() {
    local vpn_iface="$1" uplink="$2"
    [[ -z "$vpn_iface" || -z "$uplink" ]] && { echo "Usage: $0 on <vpn_iface> <uplink>"; exit 1; }

    log "Enabling kill-switch (VPN=$vpn_iface, uplink=$uplink)"

    local ifc
    for ifc in $(client_ifaces); do
        # Разрешить выход клиентов только через VPN
        iptables -C FORWARD -i "$ifc" -o "$vpn_iface" -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -i "$ifc" -o "$vpn_iface" -j ACCEPT
        # Запретить выход клиентов напрямую через uplink (анти-leak)
        iptables -C FORWARD -i "$ifc" -o "$uplink" -j DROP 2>/dev/null || \
            iptables -A FORWARD -i "$ifc" -o "$uplink" -j DROP
        ok "Block $ifc → $uplink (allow only → $vpn_iface)"
    done

    # DNS-leak protection: перехват клиентских DNS на роутер
    if [[ "$VPN_DNS_REDIRECT" == "yes" ]]; then
        for ifc in $(client_ifaces); do
            local proto
            for proto in udp tcp; do
                iptables -t nat -C PREROUTING -i "$ifc" -p "$proto" --dport 53 \
                    -j DNAT --to-destination "$WIFI_AP_IP" 2>/dev/null || \
                iptables -t nat -A PREROUTING -i "$ifc" -p "$proto" --dport 53 \
                    -j DNAT --to-destination "$WIFI_AP_IP"
            done
        done
        ok "DNS redirect → $WIFI_AP_IP (anti DNS-leak)"
    fi

    log "Kill-switch ENABLED"
}

ks_off() {
    log "Disabling kill-switch"
    local ifc proto line

    # Kill-switch добавляет только DROP-правила в FORWARD для клиентских
    # интерфейсов — снимаем именно их (ACCEPT→vpn принадлежат обычному
    # форвардингу и не трогаются).
    for ifc in $(client_ifaces); do
        while line=$(iptables -t filter -S FORWARD 2>/dev/null \
                | grep -m1 -E "^-A FORWARD -i ${ifc} .* -j DROP"); do
            [[ -z "$line" ]] && break
            # shellcheck disable=SC2086
            iptables -t filter -D ${line#-A } 2>/dev/null || break
        done

        # DNS-redirect DNAT
        for proto in udp tcp; do
            while iptables -t nat -C PREROUTING -i "$ifc" -p "$proto" --dport 53 \
                    -j DNAT --to-destination "$WIFI_AP_IP" 2>/dev/null; do
                iptables -t nat -D PREROUTING -i "$ifc" -p "$proto" --dport 53 \
                    -j DNAT --to-destination "$WIFI_AP_IP" 2>/dev/null || break
            done
        done
    done
    ok "Kill-switch rules removed"
    log "Kill-switch DISABLED"
}

ks_status() {
    echo -e "${CYAN}=== Kill-switch status ===${NC}"
    local found=0
    local ifc
    for ifc in $(client_ifaces); do
        if iptables -t filter -S FORWARD 2>/dev/null | grep -qE "^-A FORWARD -i $ifc .* -j DROP"; then
            ok "Active: $ifc blocked from leaking (DROP rule present)"
            found=1
        fi
    done
    if iptables -t nat -S PREROUTING 2>/dev/null | grep -q "dport 53 .*DNAT"; then
        ok "DNS redirect active (port 53 → $WIFI_AP_IP)"
        found=1
    fi
    [[ $found -eq 0 ]] && info "Kill-switch is OFF (no leak-protection rules)"
}

case "${1:-status}" in
    on)     shift; ks_on "${1:-}" "${2:-}" ;;
    off)    ks_off ;;
    status) ks_status ;;
    *)      echo "Usage: $0 {on <vpn_iface> <uplink>|off|status}"; exit 1 ;;
esac
