#!/bin/bash
# =============================================================================
# setup-ap.sh — настройка WiFi точки доступа (hostapd + dnsmasq)
# Orange Pi 3 LTS (AP6256/BCM4345), Armbian
#
# Вызывается из wifi-ap.service или вручную: sudo setup-ap.sh [start|stop|status]
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

WIFI_AP_IFACE="${WIFI_AP_IFACE:-wlan0}"
WIFI_AP_SSID="${WIFI_AP_SSID:-OrangePi-Router}"
WIFI_AP_PASSWORD="${WIFI_AP_PASSWORD:-changeme123}"
WIFI_AP_BAND="${WIFI_AP_BAND:-2g}"
WIFI_AP_CHANNEL_2G="${WIFI_AP_CHANNEL_2G:-6}"
WIFI_AP_CHANNEL_5G="${WIFI_AP_CHANNEL_5G:-36}"
WIFI_AP_IP="${WIFI_AP_IP:-192.168.10.1}"
WIFI_AP_DHCP_RANGE="${WIFI_AP_DHCP_RANGE:-192.168.10.100,192.168.10.200,12h}"
LOG_TAG="${LOG_TAG:-ltemod}"

TEMPLATE_DIR="/etc/ltemod/wifi"
HOSTAPD_CONF_2G="/etc/hostapd/hostapd-2g.conf"
HOSTAPD_CONF_5G="/etc/hostapd/hostapd-5g.conf"
DNSMASQ_CONF="/etc/dnsmasq.d/ltemod-ap.conf"
HOSTAPD_PID_2G="/run/hostapd-2g.pid"
HOSTAPD_PID_5G="/run/hostapd-5g.pid"
IFACE_5G="${WIFI_AP_IFACE}_5g"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { logger -t "${LOG_TAG}-ap" "$*"; echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
log_err() { logger -t "${LOG_TAG}-ap" -p user.err "$*"; echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
fail()    { echo -e "  ${RED}✗${NC} $*"; }
info()    { echo -e "  ${YELLOW}→${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
    log_err "Must be run as root"
    exit 1
fi

# ---------------------------------------------------------------------------
# Генерация конфига hostapd из шаблона
# ---------------------------------------------------------------------------
generate_hostapd_conf() {
    local band="$1"    # "2g" или "5g"
    local iface="$2"   # интерфейс
    local tmpl_src dest

    if [[ "$band" == "2g" ]]; then
        tmpl_src="$TEMPLATE_DIR/hostapd-2g.conf.template"
        dest="$HOSTAPD_CONF_2G"
    else
        tmpl_src="$TEMPLATE_DIR/hostapd-5g.conf.template"
        dest="$HOSTAPD_CONF_5G"
    fi

    if [[ ! -f "$tmpl_src" ]]; then
        log_err "Template not found: $tmpl_src"
        return 1
    fi

    sed \
        -e "s|WIFI_AP_IFACE_PLACEHOLDER|${iface}|g" \
        -e "s|WIFI_AP_SSID_PLACEHOLDER|${WIFI_AP_SSID}|g" \
        -e "s|WIFI_AP_PASSWORD_PLACEHOLDER|${WIFI_AP_PASSWORD}|g" \
        -e "s|WIFI_AP_CHANNEL_2G_PLACEHOLDER|${WIFI_AP_CHANNEL_2G}|g" \
        -e "s|WIFI_AP_CHANNEL_5G_PLACEHOLDER|${WIFI_AP_CHANNEL_5G}|g" \
        "$tmpl_src" > "$dest"

    chmod 640 "$dest"
    log "Generated hostapd config: $dest (band=${band}, iface=${iface})"
}

# ---------------------------------------------------------------------------
# Настройка dnsmasq для DHCP на WiFi AP сети
# ---------------------------------------------------------------------------
setup_dnsmasq() {
    mkdir -p /etc/dnsmasq.d

    # Определить какой/какие интерфейсы будут AP
    local ifaces="$WIFI_AP_IFACE"
    [[ "$WIFI_AP_BAND" == "both" ]] && ifaces="$WIFI_AP_IFACE $IFACE_5G"

    {
        echo "# ltemod WiFi AP DHCP — генерируется setup-ap.sh"
        echo "# НЕ редактировать вручную"
        for ifc in $ifaces; do
            echo "interface=$ifc"
        done
        echo "dhcp-range=$WIFI_AP_DHCP_RANGE"
        echo "dhcp-option=3,$WIFI_AP_IP"    # шлюз
        echo "dhcp-option=6,1.1.1.1,8.8.8.8"  # DNS
        echo "no-resolv"
        echo "server=1.1.1.1"
        echo "server=8.8.8.8"
        # Не менять разрешение hostname'ов других интерфейсов
        echo "bind-interfaces"
    } > "$DNSMASQ_CONF"

    log "Generated dnsmasq config: $DNSMASQ_CONF"
}

# ---------------------------------------------------------------------------
# Настройка iptables для AP сети
# ---------------------------------------------------------------------------
setup_ap_nat() {
    local ap_network
    ap_network=$(echo "$WIFI_AP_IP" | cut -d. -f1-3).0/24

    # MASQUERADE для исходящего трафика из AP сети
    # Реальный uplink определяется setup-routing.sh; здесь добавляем FORWARD
    if ! iptables -C FORWARD -i "$WIFI_AP_IFACE" -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -i "$WIFI_AP_IFACE" -j ACCEPT
    fi
    if ! iptables -C FORWARD -o "$WIFI_AP_IFACE" -m state \
            --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -o "$WIFI_AP_IFACE" \
            -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi

    # NAT для AP сети (трафик уходит через текущий uplink)
    if ! iptables -t nat -C POSTROUTING -s "$ap_network" -j MASQUERADE &>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$ap_network" -j MASQUERADE
    fi

    if [[ "$WIFI_AP_BAND" == "both" ]] && ip link show "$IFACE_5G" &>/dev/null; then
        if ! iptables -C FORWARD -i "$IFACE_5G" -j ACCEPT &>/dev/null; then
            iptables -A FORWARD -i "$IFACE_5G" -j ACCEPT
        fi
        if ! iptables -C FORWARD -o "$IFACE_5G" -m state \
                --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
            iptables -A FORWARD -o "$IFACE_5G" \
                -m state --state RELATED,ESTABLISHED -j ACCEPT
        fi
    fi

    log "iptables FORWARD/NAT rules added for AP network $ap_network"
}

# ---------------------------------------------------------------------------
# Запуск AP
# ---------------------------------------------------------------------------
ap_start() {
    log "=== Starting WiFi AP (band=$WIFI_AP_BAND, SSID=$WIFI_AP_SSID) ==="

    # Убедиться что rfkill не блокирует WiFi
    rfkill unblock wifi 2>/dev/null || true

    # Убить старый hostapd если запущен
    pkill -f "hostapd" 2>/dev/null || true
    sleep 1

    mkdir -p /etc/hostapd

    case "$WIFI_AP_BAND" in
        2g)
            generate_hostapd_conf "2g" "$WIFI_AP_IFACE"
            ip addr flush dev "$WIFI_AP_IFACE" 2>/dev/null || true
            ip addr add "${WIFI_AP_IP}/24" dev "$WIFI_AP_IFACE"
            ip link set "$WIFI_AP_IFACE" up
            hostapd -B -P "$HOSTAPD_PID_2G" "$HOSTAPD_CONF_2G" || {
                log_err "hostapd failed to start (2.4GHz)"
                exit 1
            }
            ok "hostapd started: 2.4 GHz on $WIFI_AP_IFACE (ch ${WIFI_AP_CHANNEL_2G})"
            ;;

        5g)
            generate_hostapd_conf "5g" "$WIFI_AP_IFACE"
            ip addr flush dev "$WIFI_AP_IFACE" 2>/dev/null || true
            ip addr add "${WIFI_AP_IP}/24" dev "$WIFI_AP_IFACE"
            ip link set "$WIFI_AP_IFACE" up
            hostapd -B -P "$HOSTAPD_PID_5G" "$HOSTAPD_CONF_5G" || {
                log_err "hostapd failed to start (5GHz)"
                exit 1
            }
            ok "hostapd started: 5 GHz on $WIFI_AP_IFACE (ch ${WIFI_AP_CHANNEL_5G})"
            ;;

        both)
            # Создать виртуальный интерфейс для 5GHz
            iw dev "$WIFI_AP_IFACE" interface add "$IFACE_5G" type __ap 2>/dev/null || {
                info "Virtual 5GHz interface $IFACE_5G already exists or not supported"
            }

            # 2.4 GHz на основном интерфейсе
            generate_hostapd_conf "2g" "$WIFI_AP_IFACE"
            ip addr flush dev "$WIFI_AP_IFACE" 2>/dev/null || true
            ip addr add "${WIFI_AP_IP}/24" dev "$WIFI_AP_IFACE"
            ip link set "$WIFI_AP_IFACE" up
            hostapd -B -P "$HOSTAPD_PID_2G" "$HOSTAPD_CONF_2G" || {
                log_err "hostapd failed to start (2.4GHz)"
                exit 1
            }
            ok "hostapd started: 2.4 GHz on $WIFI_AP_IFACE"

            # 5 GHz на виртуальном
            if ip link show "$IFACE_5G" &>/dev/null; then
                ap_5g_ip=$(echo "$WIFI_AP_IP" | sed 's/\.1$/\.65/')
                generate_hostapd_conf "5g" "$IFACE_5G"
                ip addr flush dev "$IFACE_5G" 2>/dev/null || true
                ip addr add "${ap_5g_ip}/24" dev "$IFACE_5G"
                ip link set "$IFACE_5G" up
                hostapd -B -P "$HOSTAPD_PID_5G" "$HOSTAPD_CONF_5G" || {
                    info "hostapd 5GHz failed — continuing with 2.4GHz only"
                }
                ok "hostapd started: 5 GHz on $IFACE_5G"
            else
                info "5GHz virtual interface not available — running 2.4GHz only"
            fi
            ;;

        *)
            log_err "Unknown WIFI_AP_BAND='$WIFI_AP_BAND'. Use: 2g, 5g, or both"
            exit 1
            ;;
    esac

    # DHCP
    setup_dnsmasq
    systemctl restart dnsmasq 2>/dev/null || {
        pkill -HUP dnsmasq 2>/dev/null || dnsmasq 2>/dev/null || true
    }
    ok "dnsmasq restarted (DHCP for AP)"

    # NAT
    setup_ap_nat

    log "=== WiFi AP started: SSID='$WIFI_AP_SSID' IP=$WIFI_AP_IP ==="
}

# ---------------------------------------------------------------------------
# Остановка AP
# ---------------------------------------------------------------------------
ap_stop() {
    log "Stopping WiFi AP..."

    if [[ -f "$HOSTAPD_PID_2G" ]]; then
        kill "$(cat "$HOSTAPD_PID_2G")" 2>/dev/null || true
        rm -f "$HOSTAPD_PID_2G"
    fi
    if [[ -f "$HOSTAPD_PID_5G" ]]; then
        kill "$(cat "$HOSTAPD_PID_5G")" 2>/dev/null || true
        rm -f "$HOSTAPD_PID_5G"
    fi
    pkill -f "hostapd" 2>/dev/null || true

    # Удалить виртуальный 5GHz интерфейс
    if ip link show "$IFACE_5G" &>/dev/null; then
        ip link set "$IFACE_5G" down 2>/dev/null || true
        iw dev "$IFACE_5G" del 2>/dev/null || true
    fi

    # Убрать конфиг dnsmasq
    rm -f "$DNSMASQ_CONF"
    systemctl restart dnsmasq 2>/dev/null || pkill -HUP dnsmasq 2>/dev/null || true

    ok "WiFi AP stopped"
}

# ---------------------------------------------------------------------------
# Статус AP
# ---------------------------------------------------------------------------
ap_status() {
    echo ""
    echo "=============================="
    echo "  WiFi AP Status"
    echo "=============================="

    if pgrep -f "hostapd" > /dev/null; then
        ok "hostapd: RUNNING"
    else
        fail "hostapd: NOT running"
    fi

    if ip link show "$WIFI_AP_IFACE" &>/dev/null; then
        ap_ip=$(ip addr show "$WIFI_AP_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
        ok "Interface $WIFI_AP_IFACE: UP | IP: $ap_ip"
        clients=$(iw dev "$WIFI_AP_IFACE" station dump 2>/dev/null | grep -c "^Station" || echo 0)
        info "Connected WiFi clients: $clients"
    else
        fail "Interface $WIFI_AP_IFACE: DOWN"
    fi

    if [[ "$WIFI_AP_BAND" == "both" ]] && ip link show "$IFACE_5G" &>/dev/null; then
        ap5_ip=$(ip addr show "$IFACE_5G" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
        ok "Interface $IFACE_5G (5GHz): UP | IP: $ap5_ip"
        clients5=$(iw dev "$IFACE_5G" station dump 2>/dev/null | grep -c "^Station" || echo 0)
        info "Connected WiFi clients (5GHz): $clients5"
    fi

    info "SSID: $WIFI_AP_SSID"
    info "Band: $WIFI_AP_BAND"
    info "Gateway: $WIFI_AP_IP"
    echo "=============================="
}

# === Точка входа ===
CMD="${1:-start}"
case "$CMD" in
    start)  ap_start ;;
    stop)   ap_stop ;;
    status) ap_status ;;
    restart) ap_stop; sleep 1; ap_start ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
