#!/bin/bash
# =============================================================================
# modem-status.sh — полный статус LTE роутера, WiFi AP и VPN
# =============================================================================

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

WWAN_IFACE="${WWAN_IFACE:-wwan0}"
LAN_IFACE="${LAN_IFACE:-end0}"
MODE_FILE="${MODE_FILE:-/run/ltemod/mode}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/ltemod}"

VPN_IFACE="${VPN_IFACE:-wg0}"
AMNEZIA_IFACE="${AMNEZIA_IFACE:-awg0}"
VLESS_TUN_IFACE="${VLESS_TUN_IFACE:-tun0}"

WIFI_AP_IFACE="${WIFI_AP_IFACE:-wlan0}"
WIFI_AP_SSID="${WIFI_AP_SSID:-OrangePi-Router}"
WIFI_AP_BAND="${WIFI_AP_BAND:-2g}"
WIFI_AP_ENABLED="${WIFI_AP_ENABLED:-yes}"
WIFI_CLIENT_IFACE="${WIFI_CLIENT_IFACE:-wlan1}"
WIFI_CLIENT_ENABLED="${WIFI_CLIENT_ENABLED:-no}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
info() { echo -e "  ${YELLOW}→${NC} $*"; }
section() { echo ""; echo -e "${CYAN}[ $* ]${NC}"; }

echo "============================================"
echo -e "  ${CYAN}LTE + WiFi + VPN Router Status${NC}"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

# ---------------------------------------------------------------------------
# Режим
# ---------------------------------------------------------------------------
section "Routing Mode"
mode="direct"
[[ -f "$MODE_FILE" ]] && mode=$(cat "$MODE_FILE")

case "$mode" in
    wg)      ok "Mode: WireGuard VPN" ;;
    amnezia) ok "Mode: AmneziaWG VPN (obfuscated)" ;;
    vless)   ok "Mode: VLESS (sing-box)" ;;
    *)       ok "Mode: Direct uplink (no VPN)" ;;
esac

# Текущий uplink
uplink_file="$RUNTIME_DIR/uplink_iface"
if [[ -f "$uplink_file" ]]; then
    uplink=$(cat "$uplink_file")
    info "Uplink interface: $uplink"
fi

# ---------------------------------------------------------------------------
# Modем EM7565
# ---------------------------------------------------------------------------
section "Modem (EM7565)"
if lsusb 2>/dev/null | grep -qi "sierra\|1199:"; then
    ok "USB device detected"
else
    fail "USB device NOT detected (check WS18-02 adapter)"
fi

MODEM_DEV_PATH="${MODEM_DEV:-/dev/cdc-wdm0}"
if [[ -e "$MODEM_DEV_PATH" ]]; then
    ok "Control device: $MODEM_DEV_PATH"
else
    fail "Control device $MODEM_DEV_PATH not found"
fi

if ip link show "$WWAN_IFACE" &>/dev/null; then
    wwan_state=$(ip link show "$WWAN_IFACE" | grep -o "state [A-Z]*" | awk '{print $2}')
    wwan_ip=$(ip addr show "$WWAN_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
    ok "Interface $WWAN_IFACE: $wwan_state | IP: $wwan_ip"
else
    fail "Interface $WWAN_IFACE not found"
fi

if command -v mmcli &>/dev/null; then
    modem_idx=$(mmcli -L 2>/dev/null | grep -o '/Modems/[0-9]*' | head -1 | grep -o '[0-9]*' || echo "")
    if [[ -n "$modem_idx" ]]; then
        signal=$(mmcli -m "$modem_idx" 2>/dev/null | grep -i "signal quality" | awk -F: '{print $2}' | tr -d ' ' || echo "n/a")
        operator=$(mmcli -m "$modem_idx" 2>/dev/null | grep -i "operator name" | awk -F: '{print $2}' | tr -d ' ' || echo "n/a")
        info "Operator: $operator | Signal: $signal"
    fi
fi

# NetworkManager
NM_CON="${NM_CON_NAME:-lte-connection}"
if nmcli connection show "$NM_CON" &>/dev/null; then
    nm_state=$(nmcli -g GENERAL.STATE connection show "$NM_CON" 2>/dev/null || echo "unknown")
    ok "NM connection '$NM_CON': $nm_state"
else
    fail "NM connection '$NM_CON' not found"
fi

# ---------------------------------------------------------------------------
# WiFi AP
# ---------------------------------------------------------------------------
section "WiFi Access Point"

if [[ "$WIFI_AP_ENABLED" == "yes" ]]; then
    if pgrep -f "hostapd" > /dev/null 2>&1; then
        ap_ip=$(ip addr show "$WIFI_AP_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
        clients=$(iw dev "$WIFI_AP_IFACE" station dump 2>/dev/null | grep -c "^Station" || echo 0)
        ok "hostapd: RUNNING"
        info "SSID: $WIFI_AP_SSID | Band: $WIFI_AP_BAND | IP: $ap_ip"
        info "Connected WiFi clients: $clients"
    else
        fail "WiFi AP (hostapd): NOT running"
        info "Start with: sudo systemctl start wifi-ap.service"
    fi

    # 5GHz виртуальный интерфейс
    iface_5g="${WIFI_AP_IFACE}_5g"
    if [[ "$WIFI_AP_BAND" == "both" ]] && ip link show "$iface_5g" &>/dev/null 2>&1; then
        ap5_ip=$(ip addr show "$iface_5g" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
        clients5=$(iw dev "$iface_5g" station dump 2>/dev/null | grep -c "^Station" || echo 0)
        ok "5GHz ($iface_5g): UP | IP: $ap5_ip | Clients: $clients5"
    fi
else
    info "WiFi AP: disabled in ltemod.conf (WIFI_AP_ENABLED=no)"
fi

# ---------------------------------------------------------------------------
# WiFi Client (upstream)
# ---------------------------------------------------------------------------
section "WiFi Upstream Client"

if [[ "$WIFI_CLIENT_ENABLED" == "yes" ]]; then
    if ip addr show "$WIFI_CLIENT_IFACE" &>/dev/null 2>&1; then
        wc_ip=$(ip addr show "$WIFI_CLIENT_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
        ok "Interface $WIFI_CLIENT_IFACE: UP | IP: $wc_ip"
        # Показать SSID к которому подключены
        ssid_connected=$(iw dev "$WIFI_CLIENT_IFACE" link 2>/dev/null | grep "SSID:" | awk '{print $2}' || echo "")
        [[ -n "$ssid_connected" ]] && info "Connected to: $ssid_connected"
    else
        fail "WiFi upstream ($WIFI_CLIENT_IFACE): not connected"
        info "Connect with: sudo setup-wifi-client connect"
    fi
else
    info "WiFi client: disabled (WIFI_CLIENT_ENABLED=no)"
fi

# ---------------------------------------------------------------------------
# VPN протоколы
# ---------------------------------------------------------------------------
section "VPN Protocols"

# WireGuard
if ip link show "$VPN_IFACE" &>/dev/null 2>&1; then
    vpn_ip=$(ip addr show "$VPN_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
    ok "WireGuard ($VPN_IFACE): UP | IP: $vpn_ip"
    if command -v wg &>/dev/null; then
        handshake=$(wg show "$VPN_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' || echo "0")
        if [[ -n "$handshake" && "$handshake" != "0" ]]; then
            age=$(( $(date +%s) - handshake ))
            if [[ $age -lt 180 ]]; then
                ok "  Handshake: ${age}s ago (healthy)"
            else
                fail "  Handshake: ${age}s ago (stale!)"
            fi
        else
            fail "  No WireGuard handshake yet"
        fi
    fi
else
    info "WireGuard ($VPN_IFACE): DOWN"
fi

# AmneziaWG
if ip link show "$AMNEZIA_IFACE" &>/dev/null 2>&1; then
    awg_ip=$(ip addr show "$AMNEZIA_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
    ok "AmneziaWG ($AMNEZIA_IFACE): UP | IP: $awg_ip"
    if command -v awg &>/dev/null; then
        handshake=$(awg show "$AMNEZIA_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' || echo "0")
        if [[ -n "$handshake" && "$handshake" != "0" ]]; then
            age=$(( $(date +%s) - handshake ))
            if [[ $age -lt 180 ]]; then
                ok "  Handshake: ${age}s ago (healthy)"
            else
                fail "  Handshake: ${age}s ago (stale!)"
            fi
        fi
    fi
else
    info "AmneziaWG ($AMNEZIA_IFACE): DOWN"
fi

# VLESS (sing-box)
if systemctl is-active --quiet sing-box 2>/dev/null; then
    ok "sing-box (VLESS): RUNNING"
    if ip link show "$VLESS_TUN_IFACE" &>/dev/null 2>&1; then
        ok "TUN interface $VLESS_TUN_IFACE: UP"
    else
        info "TUN $VLESS_TUN_IFACE: not yet created"
    fi
else
    info "sing-box (VLESS): not running"
fi

# ---------------------------------------------------------------------------
# Маршрутизация
# ---------------------------------------------------------------------------
section "Routing"

default_route=$(ip route show default 2>/dev/null | head -5)
if [[ -n "$default_route" ]]; then
    ok "Default route(s):"
    echo "$default_route" | while read -r line; do
        info "  $line"
    done
else
    fail "No default route!"
fi

forwarding=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
if [[ "$forwarding" == "1" ]]; then
    ok "IP forwarding: enabled"
else
    fail "IP forwarding: DISABLED"
fi

# ---------------------------------------------------------------------------
# iptables NAT
# ---------------------------------------------------------------------------
section "NAT (iptables)"
masq=$(iptables -t nat -L POSTROUTING -n 2>/dev/null | grep MASQUERADE || echo "")
if [[ -n "$masq" ]]; then
    ok "MASQUERADE rule(s):"
    echo "$masq" | while read -r line; do
        info "  $line"
    done
else
    fail "No MASQUERADE rule in iptables"
fi

# ---------------------------------------------------------------------------
# Интернет
# ---------------------------------------------------------------------------
section "Connectivity"
PING_HOST="${PING_HOST:-8.8.8.8}"
if ping -c 2 -W 3 "$PING_HOST" &>/dev/null; then
    latency=$(ping -c 3 -W 3 "$PING_HOST" 2>/dev/null | tail -1 | awk -F/ '{print $5}' || echo "?")
    ok "Internet: reachable (avg ${latency}ms)"
else
    fail "Internet: NOT reachable (ping $PING_HOST failed)"
fi

# ---------------------------------------------------------------------------
# Systemd сервисы
# ---------------------------------------------------------------------------
section "Systemd Services"
for svc in lte-modem.service lte-watchdog.timer wifi-ap.service sing-box.service; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ok "$svc: active"
    elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        fail "$svc: enabled but NOT active"
    else
        info "$svc: not installed"
    fi
done

echo ""
echo "============================================"
echo ""
echo -e "  ${YELLOW}Quick commands:${NC}"
echo "  sudo vpn-toggle wg on|off      — WireGuard"
echo "  sudo vpn-toggle amnezia on|off — AmneziaWG"
echo "  sudo vpn-toggle vless on|off   — VLESS"
echo "  sudo setup-ap.sh status        — WiFi AP detail"
echo "  sudo setup-wifi-client status  — WiFi upstream detail"
echo ""
