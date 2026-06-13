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
BRIDGE_LAN_ENABLED="${BRIDGE_LAN_ENABLED:-no}"
BRIDGE_IFACE="${BRIDGE_IFACE:-br0}"
LAN_IFACE="${LAN_IFACE:-end0}"
LOG_TAG="${LOG_TAG:-ltemod}"
BYPASS_ENABLED="${BYPASS_ENABLED:-no}"

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
# Создание Linux bridge (wlan0 + end0 → br0)
# Вызывается до запуска hostapd при BRIDGE_LAN_ENABLED=yes
# ---------------------------------------------------------------------------
setup_bridge() {
    local bridge="$BRIDGE_IFACE"
    log "Setting up bridge $bridge ($WIFI_AP_IFACE + $LAN_IFACE)..."

    # Создать bridge-интерфейс
    ip link add name "$bridge" type bridge 2>/dev/null || true
    # Отключить STP — в роутере не нужен, только замедляет
    ip link set "$bridge" type bridge stp_state 0

    # Добавить Ethernet LAN порт в bridge
    # Сначала убрать у него любые IP адреса
    ip addr flush dev "$LAN_IFACE" 2>/dev/null || true
    ip link set "$LAN_IFACE" master "$bridge"
    ip link set "$LAN_IFACE" up

    # IP назначается bridge-интерфейсу, а не wlan0
    # (wlan0 будет добавлен в bridge через hostapd bridge= директиву)
    ip addr flush dev "$WIFI_AP_IFACE" 2>/dev/null || true
    ip addr add "${WIFI_AP_IP}/24" dev "$bridge"
    ip link set "$bridge" up

    ok "Bridge $bridge created: members=$LAN_IFACE + $WIFI_AP_IFACE (via hostapd)"
    log "Bridge IP: ${WIFI_AP_IP}/24 on $bridge"
}

# ---------------------------------------------------------------------------
# Удаление bridge при остановке AP
# ---------------------------------------------------------------------------
teardown_bridge() {
    local bridge="$BRIDGE_IFACE"

    if ip link show "$bridge" &>/dev/null; then
        log "Removing bridge $bridge..."
        ip link set "$bridge" down 2>/dev/null || true

        # Освободить end0 из bridge
        ip link set "$LAN_IFACE" nomaster 2>/dev/null || true

        # Удалить bridge
        ip link delete "$bridge" type bridge 2>/dev/null || true
        ok "Bridge $bridge removed, $LAN_IFACE released"
    fi
}

# ---------------------------------------------------------------------------
# Генерация конфига hostapd из шаблона
# ---------------------------------------------------------------------------
# Экранировать спецсимволы для строки замены sed (\, &, и разделитель |)
# Без этого SSID/пароль с символами | & \ ломают подстановку и выдают
# нерабочий конфиг без явной ошибки.
sed_escape() { printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'; }

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

    local ssid_esc pass_esc
    ssid_esc=$(sed_escape "$WIFI_AP_SSID")
    pass_esc=$(sed_escape "$WIFI_AP_PASSWORD")

    sed \
        -e "s|WIFI_AP_IFACE_PLACEHOLDER|${iface}|g" \
        -e "s|WIFI_AP_SSID_PLACEHOLDER|${ssid_esc}|g" \
        -e "s|WIFI_AP_PASSWORD_PLACEHOLDER|${pass_esc}|g" \
        -e "s|WIFI_AP_CHANNEL_2G_PLACEHOLDER|${WIFI_AP_CHANNEL_2G}|g" \
        -e "s|WIFI_AP_CHANNEL_5G_PLACEHOLDER|${WIFI_AP_CHANNEL_5G}|g" \
        "$tmpl_src" > "$dest"

    # В bridge-режиме: hostapd сам добавляет wlan0 в bridge через параметр bridge=
    if [[ "$BRIDGE_LAN_ENABLED" == "yes" ]]; then
        echo "bridge=${BRIDGE_IFACE}" >> "$dest"
        log "Added bridge=${BRIDGE_IFACE} to hostapd config"
    fi

    chmod 640 "$dest"
    log "Generated hostapd config: $dest (band=${band}, iface=${iface})"
}

# ---------------------------------------------------------------------------
# Настройка dnsmasq для DHCP
# ---------------------------------------------------------------------------
setup_dnsmasq() {
    mkdir -p /etc/dnsmasq.d

    # В bridge-режиме dnsmasq слушает на br0 (объединённый интерфейс)
    # В обычном режиме — на wlan0 (и wlan0_5g при band=both)
    local listen_ifaces
    if [[ "$BRIDGE_LAN_ENABLED" == "yes" ]]; then
        listen_ifaces="$BRIDGE_IFACE"
    else
        listen_ifaces="$WIFI_AP_IFACE"
        [[ "$WIFI_AP_BAND" == "both" ]] && listen_ifaces="$WIFI_AP_IFACE $IFACE_5G"
    fi

    {
        echo "# ltemod WiFi AP DHCP — генерируется setup-ap.sh"
        echo "# НЕ редактировать вручную"
        for ifc in $listen_ifaces; do
            echo "interface=$ifc"
        done
        echo "dhcp-range=$WIFI_AP_DHCP_RANGE"
        echo "dhcp-option=3,$WIFI_AP_IP"           # шлюз
        # DNS клиентам = сам роутер (dnsmasq). Upstream-запросы dnsmasq уходят
        # через активный маршрут (включая VPN) — защита от DNS-leak.
        echo "dhcp-option=6,$WIFI_AP_IP"           # DNS = роутер
        echo "no-resolv"
        echo "server=1.1.1.1"
        echo "server=8.8.8.8"
        echo "bind-interfaces"
        # Bypass routing: подключить каталог с ipset-правилами для доменов
        # bypass.conf генерируется list-manager.sh при загрузке списков
        if [[ "$BYPASS_ENABLED" == "yes" ]]; then
            mkdir -p /etc/dnsmasq.d/bypass
            echo "conf-dir=/etc/dnsmasq.d/bypass,*.conf"
        fi
    } > "$DNSMASQ_CONF"

    log "Generated dnsmasq config: $DNSMASQ_CONF (interfaces: $listen_ifaces)"
}

# ---------------------------------------------------------------------------
# Настройка iptables для AP / bridge сети
# ---------------------------------------------------------------------------
setup_ap_nat() {
    local ap_network
    ap_network=$(echo "$WIFI_AP_IP" | cut -d. -f1-3).0/24

    if [[ "$BRIDGE_LAN_ENABLED" == "yes" ]]; then
        # Bridge-режим: FORWARD через br0 (охватывает и wlan0, и end0)
        if ! iptables -C FORWARD -i "$BRIDGE_IFACE" -j ACCEPT &>/dev/null 2>&1; then
            iptables -A FORWARD -i "$BRIDGE_IFACE" -j ACCEPT
        fi
        if ! iptables -C FORWARD -o "$BRIDGE_IFACE" -m state \
                --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null 2>&1; then
            iptables -A FORWARD -o "$BRIDGE_IFACE" \
                -m state --state RELATED,ESTABLISHED -j ACCEPT
        fi
    else
        # Обычный режим: FORWARD для wlan0 (и wlan0_5g при band=both)
        if ! iptables -C FORWARD -i "$WIFI_AP_IFACE" -j ACCEPT &>/dev/null; then
            iptables -A FORWARD -i "$WIFI_AP_IFACE" -j ACCEPT
        fi
        if ! iptables -C FORWARD -o "$WIFI_AP_IFACE" -m state \
                --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
            iptables -A FORWARD -o "$WIFI_AP_IFACE" \
                -m state --state RELATED,ESTABLISHED -j ACCEPT
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
    fi

    # NAT: MASQUERADE для AP сети (через активный uplink)
    if ! iptables -t nat -C POSTROUTING -s "$ap_network" -j MASQUERADE &>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$ap_network" -j MASQUERADE
    fi

    local fwd_iface
    fwd_iface=$( [[ "$BRIDGE_LAN_ENABLED" == "yes" ]] && echo "$BRIDGE_IFACE" || echo "$WIFI_AP_IFACE" )
    log "iptables FORWARD/NAT rules added for AP network $ap_network (via $fwd_iface)"
}

# ---------------------------------------------------------------------------
# Preflight: поймать типовые ошибки конфига ДО запуска hostapd
# ---------------------------------------------------------------------------
ap_preflight() {
    local errors=0

    # Длина пароля WPA: 8..63 (иначе hostapd молча падает)
    local plen=${#WIFI_AP_PASSWORD}
    if (( plen < 8 || plen > 63 )); then
        log_err "WIFI_AP_PASSWORD must be 8..63 chars (now: $plen). Fix /etc/ltemod/ltemod.conf"
        errors=$((errors+1))
    fi

    # Валидность канала
    if [[ "$WIFI_AP_BAND" == "2g" || "$WIFI_AP_BAND" == "both" ]]; then
        if ! [[ "$WIFI_AP_CHANNEL_2G" =~ ^[0-9]+$ ]] || (( WIFI_AP_CHANNEL_2G < 1 || WIFI_AP_CHANNEL_2G > 13 )); then
            log_err "WIFI_AP_CHANNEL_2G='$WIFI_AP_CHANNEL_2G' invalid (use 1..13)"
            errors=$((errors+1))
        fi
    fi

    # Интерфейс существует
    if ! ip link show "$WIFI_AP_IFACE" &>/dev/null; then
        log_err "WiFi interface '$WIFI_AP_IFACE' not found. Run: detect-hardware.sh"
        errors=$((errors+1))
    fi

    if (( errors > 0 )); then
        log_err "Preflight failed ($errors error(s)). Подробнее: sudo ltemod-doctor"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Запуск AP
# ---------------------------------------------------------------------------
ap_start() {
    log "=== Starting WiFi AP (band=$WIFI_AP_BAND, SSID=$WIFI_AP_SSID, bridge=$BRIDGE_LAN_ENABLED) ==="

    ap_preflight || exit 1

    rfkill unblock wifi 2>/dev/null || true

    # Убить старый hostapd
    pkill -f "hostapd" 2>/dev/null || true
    sleep 1

    mkdir -p /etc/hostapd

    # В bridge-режиме: создать br0 ДО запуска hostapd
    # hostapd добавит wlan0 в br0 через параметр bridge= в конфиге
    if [[ "$BRIDGE_LAN_ENABLED" == "yes" ]]; then
        setup_bridge
    fi

    case "$WIFI_AP_BAND" in
        2g)
            generate_hostapd_conf "2g" "$WIFI_AP_IFACE"
            if [[ "$BRIDGE_LAN_ENABLED" != "yes" ]]; then
                ip addr flush dev "$WIFI_AP_IFACE" 2>/dev/null || true
                ip addr add "${WIFI_AP_IP}/24" dev "$WIFI_AP_IFACE"
            fi
            ip link set "$WIFI_AP_IFACE" up
            hostapd -B -P "$HOSTAPD_PID_2G" "$HOSTAPD_CONF_2G" || {
                log_err "hostapd failed to start (2.4GHz)"
                exit 1
            }
            ok "hostapd started: 2.4 GHz on $WIFI_AP_IFACE (ch ${WIFI_AP_CHANNEL_2G})"
            ;;

        5g)
            generate_hostapd_conf "5g" "$WIFI_AP_IFACE"
            if [[ "$BRIDGE_LAN_ENABLED" != "yes" ]]; then
                ip addr flush dev "$WIFI_AP_IFACE" 2>/dev/null || true
                ip addr add "${WIFI_AP_IP}/24" dev "$WIFI_AP_IFACE"
            fi
            ip link set "$WIFI_AP_IFACE" up
            hostapd -B -P "$HOSTAPD_PID_5G" "$HOSTAPD_CONF_5G" || {
                log_err "hostapd failed to start (5GHz)"
                exit 1
            }
            ok "hostapd started: 5 GHz on $WIFI_AP_IFACE (ch ${WIFI_AP_CHANNEL_5G})"
            ;;

        both)
            # bridge=both несовместим с виртуальным 5GHz — только 2.4GHz в bridge
            if [[ "$BRIDGE_LAN_ENABLED" == "yes" ]]; then
                info "Bridge mode: only 2.4GHz supported with bridge (ignoring 5GHz virtual iface)"
                generate_hostapd_conf "2g" "$WIFI_AP_IFACE"
                ip link set "$WIFI_AP_IFACE" up
                hostapd -B -P "$HOSTAPD_PID_2G" "$HOSTAPD_CONF_2G" || {
                    log_err "hostapd failed to start"
                    exit 1
                }
                ok "hostapd started: 2.4 GHz on $WIFI_AP_IFACE (bridge mode)"
            else
                # Создать виртуальный интерфейс для 5GHz
                iw dev "$WIFI_AP_IFACE" interface add "$IFACE_5G" type __ap 2>/dev/null || {
                    info "Virtual 5GHz interface $IFACE_5G already exists or not supported"
                }

                generate_hostapd_conf "2g" "$WIFI_AP_IFACE"
                ip addr flush dev "$WIFI_AP_IFACE" 2>/dev/null || true
                ip addr add "${WIFI_AP_IP}/24" dev "$WIFI_AP_IFACE"
                ip link set "$WIFI_AP_IFACE" up
                hostapd -B -P "$HOSTAPD_PID_2G" "$HOSTAPD_CONF_2G" || {
                    log_err "hostapd failed to start (2.4GHz)"
                    exit 1
                }
                ok "hostapd started: 2.4 GHz on $WIFI_AP_IFACE"

                if ip link show "$IFACE_5G" &>/dev/null; then
                    # 5GHz получает отдельный host-октет (.65) в той же /24 подсети,
                    # независимо от того, чем заканчивается WIFI_AP_IP
                    ap_5g_ip="$(echo "$WIFI_AP_IP" | cut -d. -f1-3).65"
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

    # iptables
    setup_ap_nat

    if [[ "$BRIDGE_LAN_ENABLED" == "yes" ]]; then
        log "=== WiFi AP + LAN bridge started: SSID='$WIFI_AP_SSID' bridge=$BRIDGE_IFACE IP=$WIFI_AP_IP ==="
    else
        log "=== WiFi AP started: SSID='$WIFI_AP_SSID' IP=$WIFI_AP_IP ==="
    fi
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

    # Удалить bridge если использовался
    if [[ "$BRIDGE_LAN_ENABLED" == "yes" ]]; then
        teardown_bridge
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

    if [[ "$BRIDGE_LAN_ENABLED" == "yes" ]]; then
        if ip link show "$BRIDGE_IFACE" &>/dev/null; then
            br_ip=$(ip addr show "$BRIDGE_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
            ok "Bridge $BRIDGE_IFACE: UP | IP: $br_ip"
            info "Members: $WIFI_AP_IFACE (WiFi) + $LAN_IFACE (Ethernet/кабель)"
            clients=$(iw dev "$WIFI_AP_IFACE" station dump 2>/dev/null | grep -c "^Station" || echo 0)
            info "WiFi clients: $clients"
        else
            fail "Bridge $BRIDGE_IFACE: DOWN"
        fi
    else
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
    fi

    info "SSID: $WIFI_AP_SSID"
    info "Band: $WIFI_AP_BAND"
    info "Gateway: $WIFI_AP_IP"
    info "Bridge LAN: $BRIDGE_LAN_ENABLED"
    echo "=============================="
}

# === Точка входа ===
CMD="${1:-start}"
case "$CMD" in
    start)   ap_start ;;
    stop)    ap_stop ;;
    status)  ap_status ;;
    restart) ap_stop; sleep 1; ap_start ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
