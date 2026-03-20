#!/bin/bash
# =============================================================================
# modem-status.sh — статус LTE-модема и соединений
# =============================================================================

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

WWAN_IFACE="${WWAN_IFACE:-wwan0}"
VPN_IFACE="${VPN_IFACE:-wg0}"
LAN_IFACE="${LAN_IFACE:-end0}"
MODE_FILE="${MODE_FILE:-/run/ltemod/mode}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
info() { echo -e "  ${YELLOW}→${NC} $*"; }

echo "============================================"
echo "  LTE Modem + VPN Status"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

# --- Текущий режим ---
echo ""
echo "[ Routing Mode ]"
if [[ -f "$MODE_FILE" ]]; then
    mode=$(cat "$MODE_FILE")
    if [[ "$mode" == "vpn" ]]; then
        ok "Mode: VPN (traffic via WireGuard)"
    else
        ok "Mode: Direct LTE (no VPN)"
    fi
else
    info "Mode: unknown (mode file not found)"
fi

# --- Модем ---
echo ""
echo "[ Modem (EM7565) ]"
if lsusb 2>/dev/null | grep -qi "sierra\|1199:"; then
    ok "USB device detected"
else
    fail "USB device NOT detected (check WS18-02 adapter connection)"
fi

if [[ -e "${MODEM_DEV:-/dev/cdc-wdm0}" ]]; then
    ok "Control device: ${MODEM_DEV:-/dev/cdc-wdm0}"
else
    fail "Control device ${MODEM_DEV:-/dev/cdc-wdm0} not found"
fi

if ip link show "$WWAN_IFACE" &>/dev/null; then
    wwan_state=$(ip link show "$WWAN_IFACE" | grep -o "state [A-Z]*" | awk '{print $2}')
    wwan_ip=$(ip addr show "$WWAN_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
    ok "Interface $WWAN_IFACE: $wwan_state | IP: $wwan_ip"
else
    fail "Interface $WWAN_IFACE not found"
fi

# Signal quality через ModemManager
if command -v mmcli &>/dev/null; then
    modem_idx=$(mmcli -L 2>/dev/null | grep -o '/Modems/[0-9]*' | head -1 | grep -o '[0-9]*' || echo "")
    if [[ -n "$modem_idx" ]]; then
        signal=$(mmcli -m "$modem_idx" 2>/dev/null | grep -i "signal quality" | awk -F: '{print $2}' | tr -d ' ' || echo "n/a")
        operator=$(mmcli -m "$modem_idx" 2>/dev/null | grep -i "operator name" | awk -F: '{print $2}' | tr -d ' ' || echo "n/a")
        info "Operator: $operator | Signal: $signal"
    fi
fi

# --- NetworkManager ---
echo ""
echo "[ NetworkManager ]"
NM_CON="${NM_CON_NAME:-lte-connection}"
if nmcli connection show "$NM_CON" &>/dev/null; then
    nm_state=$(nmcli -g GENERAL.STATE connection show "$NM_CON" 2>/dev/null || echo "unknown")
    ok "NM connection '$NM_CON': $nm_state"
else
    fail "NM connection '$NM_CON' not found"
fi

# --- WireGuard ---
echo ""
echo "[ WireGuard VPN ]"
if ip link show "$VPN_IFACE" &>/dev/null; then
    vpn_ip=$(ip addr show "$VPN_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
    ok "Interface $VPN_IFACE is UP | IP: $vpn_ip"
    if command -v wg &>/dev/null; then
        handshake=$(wg show "$VPN_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' || echo "0")
        if [[ -n "$handshake" && "$handshake" != "0" ]]; then
            age=$(( $(date +%s) - handshake ))
            if [[ $age -lt 180 ]]; then
                ok "Last handshake: ${age}s ago (healthy)"
            else
                fail "Last handshake: ${age}s ago (stale, check VPN server)"
            fi
        else
            fail "No handshake yet"
        fi
    fi
else
    info "Interface $VPN_IFACE is DOWN (VPN mode inactive)"
fi

# --- Маршруты ---
echo ""
echo "[ Routing ]"
default_route=$(ip route show default 2>/dev/null | head -3)
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

# --- iptables ---
echo ""
echo "[ NAT (iptables) ]"
masq=$(iptables -t nat -L POSTROUTING -n 2>/dev/null | grep MASQUERADE || echo "")
if [[ -n "$masq" ]]; then
    ok "MASQUERADE rule found:"
    echo "$masq" | while read -r line; do
        info "  $line"
    done
else
    fail "No MASQUERADE rule in iptables"
fi

# --- Интернет ---
echo ""
echo "[ Connectivity ]"
PING_HOST="${PING_HOST:-8.8.8.8}"
if ping -c 2 -W 3 "$PING_HOST" &>/dev/null; then
    latency=$(ping -c 3 -W 3 "$PING_HOST" 2>/dev/null | tail -1 | awk -F/ '{print $5}' || echo "?")
    ok "Internet: reachable (avg latency: ${latency}ms)"
else
    fail "Internet: NOT reachable (ping $PING_HOST failed)"
fi

# --- Systemd сервисы ---
echo ""
echo "[ Systemd Services ]"
for svc in lte-modem.service lte-watchdog.timer; do
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
