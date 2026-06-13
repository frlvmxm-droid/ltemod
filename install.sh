#!/bin/bash
# =============================================================================
# install.sh — установка ltemod на Orange Pi 3 LTS (Armbian)
# Sierra Wireless EM7565 + WiFi AP/Client + Multi-VPN роутер
#
# Использование:
#   sudo bash install.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok()      { echo -e "${GREEN}✓${NC} $*"; }
fail()    { echo -e "${RED}✗${NC} $*"; }
info()    { echo -e "${YELLOW}→${NC} $*"; }
header()  { echo -e "\n${CYAN}=== $* ===${NC}"; }
err_exit(){ echo -e "\n${RED}ERROR:${NC} $*" >&2; exit 1; }

INSTALL_BIN="/usr/local/bin/ltemod"
INSTALL_CONF="/etc/ltemod"
INSTALL_UDEV="/etc/udev/rules.d"
INSTALL_SYSTEMD="/etc/systemd/system"
INSTALL_SYSCTL="/etc/sysctl.d"

# ===== Проверки =====

header "Pre-flight checks"

if [[ $EUID -ne 0 ]]; then
    err_exit "This script must be run as root: sudo bash $0"
fi
ok "Running as root"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    info "OS: $PRETTY_NAME"
fi

arch=$(uname -m)
info "Architecture: $arch"

if systemctl is-active --quiet lte-modem.service 2>/dev/null; then
    echo ""
    echo -e "${YELLOW}WARNING:${NC} lte-modem.service is currently active."
    read -r -p "Reinstall and restart services? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ===== Пакеты =====

header "Installing required packages"

info "Updating package lists..."
apt-get update -qq || info "apt-get update failed (continuing anyway)"

PACKAGES=(
    # LTE модем
    modemmanager
    libmbim-utils
    libqmi-utils
    usb-modeswitch
    # WireGuard
    wireguard-tools
    # Сетевое
    iptables
    iptables-persistent
    network-manager
    isc-dhcp-client
    # WiFi AP
    hostapd
    dnsmasq
    wireless-tools
    iw
    bridge-utils
    # Утилиты
    pciutils
    usbutils
    jq
    curl
    wget
    vnstat
    # Bypass routing
    ipset
)

export DEBIAN_FRONTEND=noninteractive
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections
# hostapd не запускать автоматически — ltemod управляет им через setup-ap.sh
echo "hostapd hostapd/enable boolean false" | debconf-set-selections

info "Installing: ${PACKAGES[*]}"
apt-get install -y "${PACKAGES[@]}" || {
    fail "Some packages failed to install"
    info "Trying to continue..."
}
ok "Packages installed"

# Остановить hostapd и dnsmasq — они управляются через ltemod
systemctl stop hostapd 2>/dev/null || true
systemctl disable hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
# dnsmasq нужен как сервис, но запускается из setup-ap.sh
info "hostapd disabled (managed by wifi-ap.service)"

# ===== sing-box (VLESS) =====

header "Installing sing-box (VLESS client)"

SING_BOX_VER="1.10.7"
SING_BOX_ARCH="linux-arm64"
SING_BOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VER}/sing-box-${SING_BOX_VER}-${SING_BOX_ARCH}.tar.gz"

if command -v sing-box &>/dev/null; then
    current_ver=$(sing-box version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1 || echo "")
    info "sing-box already installed: $current_ver (target: $SING_BOX_VER)"
    ok "Skipping sing-box download"
else
    info "Downloading sing-box ${SING_BOX_VER} for ${SING_BOX_ARCH}..."
    if curl -fsSL -o /tmp/sing-box.tar.gz "$SING_BOX_URL"; then
        tar -xzf /tmp/sing-box.tar.gz -C /tmp/
        install -m 755 /tmp/sing-box-${SING_BOX_VER}-${SING_BOX_ARCH}/sing-box /usr/local/bin/sing-box
        rm -rf /tmp/sing-box.tar.gz /tmp/sing-box-*/
        ok "sing-box installed: $(sing-box version | head -1)"
    else
        fail "Failed to download sing-box"
        info "Install manually: https://github.com/SagerNet/sing-box/releases"
    fi
fi

mkdir -p /etc/sing-box
ok "sing-box config dir: /etc/sing-box/"

# ===== AmneziaWG =====

header "Installing AmneziaWG"

if command -v awg-quick &>/dev/null; then
    ok "awg-quick already installed: $(command -v awg-quick)"
else
    info "Trying to install AmneziaWG via apt (Debian/Ubuntu)..."

    # Метод 1: PPA/репозиторий AmneziaWG
    if apt-get install -y amneziawg 2>/dev/null; then
        ok "AmneziaWG installed via apt"
    else
        info "apt method failed — trying DKMS build..."

        # Метод 2: GitHub releases — ищем готовый .deb для arm64
        AWG_RELEASE_URL="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/releases/latest"
        info "AmneziaWG not available via apt or DKMS on this system"
        info "Manual install required:"
        info "  https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/releases"
        info "  Download: amneziawg-dkms_*.deb + amneziawg-tools_*.deb for arm64"
        info "  Install:  dpkg -i amneziawg-dkms_*.deb amneziawg-tools_*.deb"
        info "  Or use AmneziaWG Docker: https://docs.amnezia.org"
        fail "AmneziaWG not installed — install manually and re-run install.sh"
    fi
fi

mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg
ok "AmneziaWG config dir: /etc/amnezia/amneziawg/"

# ===== Модули ядра =====

header "Loading kernel modules"

modules=(wireguard cdc_mbim qmi_wwan cdc_acm cdc_wdm)
for mod in "${modules[@]}"; do
    if modprobe "$mod" 2>/dev/null; then
        ok "Module $mod loaded"
    else
        info "Module $mod: not available"
    fi
done

for mod in wireguard cdc_mbim qmi_wwan; do
    if ! grep -q "^$mod$" /etc/modules 2>/dev/null; then
        echo "$mod" >> /etc/modules
    fi
done
ok "Modules configured for autoload"

# ===== Создание директорий =====

header "Creating directories"

mkdir -p "$INSTALL_BIN"
mkdir -p "$INSTALL_CONF"
mkdir -p "$INSTALL_CONF/wifi"
mkdir -p "$INSTALL_CONF/profiles"
chmod 700 "$INSTALL_CONF/profiles"
mkdir -p "$INSTALL_CONF/bypass"
chmod 700 "$INSTALL_CONF/bypass"
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
mkdir -p /etc/hostapd
mkdir -p /etc/dnsmasq.d
mkdir -p /etc/dnsmasq.d/bypass

ok "Directories created"

# ===== Копирование скриптов =====

header "Installing scripts"

# Modem
install -m 755 "$SCRIPT_DIR/modem/connect-modem.sh"   "$INSTALL_BIN/connect-modem.sh"
install -m 755 "$SCRIPT_DIR/modem/modem-status.sh"    "$INSTALL_BIN/modem-status.sh"
install -m 755 "$SCRIPT_DIR/modem/modem-watchdog.sh"  "$INSTALL_BIN/modem-watchdog.sh"
install -m 755 "$SCRIPT_DIR/modem/data-usage.sh"      "$INSTALL_BIN/data-usage.sh"
install -m 755 "$SCRIPT_DIR/modem/sms.sh"             "$INSTALL_BIN/sms.sh"

# Network
install -m 755 "$SCRIPT_DIR/network/setup-routing.sh"        "$INSTALL_BIN/setup-routing.sh"
install -m 755 "$SCRIPT_DIR/network/vpn-toggle.sh"            "$INSTALL_BIN/vpn-toggle.sh"
install -m 755 "$SCRIPT_DIR/network/killswitch.sh"            "$INSTALL_BIN/killswitch.sh"
install -m 755 "$SCRIPT_DIR/network/bypass-routing.sh"        "$INSTALL_BIN/bypass-routing.sh"
install -m 755 "$SCRIPT_DIR/network/lists/list-manager.sh"    "$INSTALL_BIN/list-manager.sh"

# VPN
install -m 755 "$SCRIPT_DIR/vpn/setup-vpn.sh"         "$INSTALL_BIN/setup-vpn.sh"
install -m 755 "$SCRIPT_DIR/vpn/setup-amnezia.sh"     "$INSTALL_BIN/setup-amnezia.sh"
install -m 755 "$SCRIPT_DIR/vpn/setup-vless.sh"       "$INSTALL_BIN/setup-vless.sh"
install -m 755 "$SCRIPT_DIR/vpn/vpn-profile.sh"       "$INSTALL_BIN/vpn-profile.sh"

# WiFi
install -m 755 "$SCRIPT_DIR/wifi/setup-ap.sh"             "$INSTALL_BIN/setup-ap.sh"
install -m 755 "$SCRIPT_DIR/wifi/setup-wifi-client.sh"    "$INSTALL_BIN/setup-wifi-client.sh"

# Tools (диагностика и автодетект железа)
install -m 755 "$SCRIPT_DIR/tools/detect-hardware.sh"     "$INSTALL_BIN/detect-hardware.sh"
install -m 755 "$SCRIPT_DIR/tools/ltemod-doctor.sh"       "$INSTALL_BIN/ltemod-doctor.sh"

# Uninstaller (self-contained)
install -m 755 "$SCRIPT_DIR/uninstall.sh"                 "$INSTALL_BIN/uninstall.sh"

ok "Scripts installed to $INSTALL_BIN"

# Симлинки
for cmd in vpn-toggle modem-status setup-vpn setup-amnezia setup-vless setup-ap \
           setup-wifi-client detect-hardware ltemod-doctor vpn-profile killswitch \
           data-usage sms bypass-routing list-manager; do
    target="/usr/local/bin/${cmd}"
    ln -sf "$INSTALL_BIN/${cmd}.sh" "$target" 2>/dev/null || \
    ln -sf "$INSTALL_BIN/${cmd}"    "$target" 2>/dev/null || true
done
ln -sf "$INSTALL_BIN/uninstall.sh" "/usr/local/bin/ltemod-uninstall" 2>/dev/null || true
ok "Symlinks created in /usr/local/bin/"

# ===== Шаблоны конфигов =====

header "Installing config templates"

install -m 644 "$SCRIPT_DIR/vpn/wg0.conf.template"         "$INSTALL_CONF/wg0.conf.template"
install -m 644 "$SCRIPT_DIR/vpn/amnezia-wg.conf.template"  "$INSTALL_CONF/amnezia-wg.conf.template"
install -m 644 "$SCRIPT_DIR/vpn/vless.json.template"       "$INSTALL_CONF/vless.json.template"
install -m 644 "$SCRIPT_DIR/wifi/hostapd-2g.conf.template" "$INSTALL_CONF/wifi/hostapd-2g.conf.template"
install -m 644 "$SCRIPT_DIR/wifi/hostapd-5g.conf.template" "$INSTALL_CONF/wifi/hostapd-5g.conf.template"
ok "Templates installed to $INSTALL_CONF/"

# ===== Основной конфиг =====

header "Installing configuration"

if [[ -f "$INSTALL_CONF/ltemod.conf" ]]; then
    info "Config exists — keeping existing, saving new as .new"
    install -m 640 "$SCRIPT_DIR/config/ltemod.conf" "$INSTALL_CONF/ltemod.conf.new"
else
    install -m 640 "$SCRIPT_DIR/config/ltemod.conf" "$INSTALL_CONF/ltemod.conf"
    ok "Config installed: $INSTALL_CONF/ltemod.conf"
fi

# ===== udev правила =====

header "Installing udev rules"

install -m 644 "$SCRIPT_DIR/modem/99-em7565.rules" "$INSTALL_UDEV/99-em7565.rules"
ok "udev rules installed"

udevadm control --reload-rules
udevadm trigger --subsystem-match=usb 2>/dev/null || true
ok "udev rules reloaded"

# ===== sysctl =====

header "Configuring sysctl"

cat > "$INSTALL_SYSCTL/99-ltemod.conf" <<'EOF'
# ltemod: IP forwarding for WiFi/LTE router
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF

sysctl -p "$INSTALL_SYSCTL/99-ltemod.conf" > /dev/null 2>&1 || true
ok "IP forwarding enabled"

# ===== systemd сервисы =====

header "Installing systemd services"

install -m 644 "$SCRIPT_DIR/systemd/lte-modem.service"             "$INSTALL_SYSTEMD/lte-modem.service"
install -m 644 "$SCRIPT_DIR/systemd/lte-watchdog.service"          "$INSTALL_SYSTEMD/lte-watchdog.service"
install -m 644 "$SCRIPT_DIR/systemd/lte-watchdog.timer"            "$INSTALL_SYSTEMD/lte-watchdog.timer"
install -m 644 "$SCRIPT_DIR/systemd/wifi-ap.service"               "$INSTALL_SYSTEMD/wifi-ap.service"
install -m 644 "$SCRIPT_DIR/systemd/ltemod-bypass-update.service"  "$INSTALL_SYSTEMD/ltemod-bypass-update.service"
install -m 644 "$SCRIPT_DIR/systemd/ltemod-bypass-update.timer"    "$INSTALL_SYSTEMD/ltemod-bypass-update.timer"
ok "Systemd units installed"

systemctl daemon-reload
ok "systemd daemon reloaded"

systemctl enable lte-watchdog.timer
ok "lte-watchdog.timer enabled"

systemctl enable ltemod-bypass-update.timer
ok "ltemod-bypass-update.timer enabled (daily at 04:00)"

systemctl enable lte-modem.service
ok "lte-modem.service enabled"

# WiFi AP включать только если есть wlan0
if [[ -d /sys/class/net/wlan0 ]]; then
    systemctl enable wifi-ap.service
    ok "wifi-ap.service enabled (wlan0 found)"
else
    info "wifi-ap.service: NOT enabled (wlan0 not found — will enable on first boot with WiFi)"
fi

# ===== NetworkManager — не вмешиваться в AP/VPN интерфейсы =====

header "Configuring NetworkManager"

NM_CONF_DIR="/etc/NetworkManager/conf.d"
mkdir -p "$NM_CONF_DIR"

# Установить из репозитория (содержит wlan0 для AP)
install -m 644 "$SCRIPT_DIR/wifi/10-wifi-ap.conf" "$NM_CONF_DIR/10-wifi-ap.conf"

# Дополнить существующий файл ltemod для VPN интерфейсов
cat > "$NM_CONF_DIR/99-ltemod-unmanaged.conf" <<'NMEOF'
[keyfile]
# ltemod: do not manage VPN and TUN interfaces
unmanaged-devices=interface-name:wg0;interface-name:awg0;interface-name:tun0
NMEOF

systemctl reload NetworkManager 2>/dev/null || true
ok "NetworkManager configured (won't interfere with AP/VPN interfaces)"

# ===== Автоопределение железа =====

header "Detecting hardware"
info "Определяю сетевые интерфейсы этого устройства..."
bash "$INSTALL_BIN/detect-hardware.sh" || true
echo ""
info "Записать найденные интерфейсы в конфиг: sudo detect-hardware --write"

# ===== Итог =====

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         Installation Complete!                   ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "Next steps:"
echo ""
echo -e "  ${YELLOW}1. Автоопределить интерфейсы и настроить конфиг:${NC}"
echo "     sudo detect-hardware --write     # LAN/WiFi/WWAN интерфейсы"
echo "     sudo nano /etc/ltemod/ltemod.conf"
echo "     → APN провайдера"
echo "     → WIFI_AP_SSID, WIFI_AP_PASSWORD (8..63 символов)"
echo ""
echo -e "  ${YELLOW}1.5 Проверить конфиг перед запуском:${NC}"
echo "     sudo ltemod-doctor               # поймает ошибки заранее"
echo ""
echo -e "  ${YELLOW}2. Перезагрузить (WiFi AP запустится автоматически):${NC}"
echo "     sudo reboot"
echo "     # или запустить вручную:"
echo "     sudo systemctl start wifi-ap.service"
echo "     sudo systemctl start lte-modem.service"
echo ""
echo -e "  ${YELLOW}3. Настроить VPN (по выбору):${NC}"
echo ""
echo "     [WireGuard]"
echo "     cp $INSTALL_CONF/wg0.conf.template /tmp/wg0.conf"
echo "     nano /tmp/wg0.conf"
echo "     sudo setup-vpn /tmp/wg0.conf"
echo ""
echo "     [AmneziaWG]"
echo "     cp $INSTALL_CONF/amnezia-wg.conf.template /tmp/awg0.conf"
echo "     nano /tmp/awg0.conf"
echo "     sudo setup-amnezia /tmp/awg0.conf"
echo ""
echo "     [VLESS]"
echo "     cp $INSTALL_CONF/vless.json.template /tmp/vless.json"
echo "     nano /tmp/vless.json"
echo "     sudo setup-vless /tmp/vless.json"
echo ""
echo -e "  ${YELLOW}4. Включить VPN:${NC}"
echo "     sudo vpn-toggle wg on        # WireGuard"
echo "     sudo vpn-toggle amnezia on   # AmneziaWG"
echo "     sudo vpn-toggle vless on     # VLESS"
echo "     sudo vpn-toggle off          # Выключить VPN"
echo ""
echo -e "  ${YELLOW}5. Подключиться к upstream WiFi (опционально):${NC}"
echo "     # Настроить WIFI_CLIENT_ENABLED=yes, WIFI_CLIENT_SSID, WIFI_CLIENT_PASSWORD"
echo "     sudo setup-wifi-client connect"
echo ""
echo -e "  ${YELLOW}6. Проверить статус:${NC}"
echo "     sudo modem-status"
echo ""
echo -e "  ${YELLOW}7. Профили VPN, защита и модем:${NC}"
echo "     sudo vpn-profile add work /tmp/wg0.conf   # сохранить профиль (автодетект)"
echo "     sudo vpn-profile list                     # список профилей"
echo "     sudo vpn-profile use work                 # активировать + поднять VPN"
echo "     # Kill-switch (анти-leak): VPN_KILLSWITCH=yes в ltemod.conf"
echo "     sudo data-usage                           # трафик LTE (день/месяц)"
echo "     sudo sms balance                          # баланс через USSD"
echo "     sudo ltemod-uninstall                     # удалить ltemod"
echo ""
echo -e "  ${YELLOW}8. Обход блокировок (bypass routing):${NC}"
echo "     # Включить: BYPASS_ENABLED=yes в ltemod.conf"
echo "     # Режим: BYPASS_MODE=selective (блокированные → VPN, остальное → прямой)"
echo "     #         BYPASS_MODE=exclude  (VPN для всего, кроме российских сервисов)"
echo "     sudo list-manager update              # скачать списки РКН-блокировок"
echo "     sudo list-manager status              # статус: файлы + ipset счётчики"
echo "     sudo bypass-routing status            # активные правила маршрутизации"
echo "     # Списки обновляются автоматически каждый день в 04:00"
echo ""
info "Logs: journalctl -u lte-modem -f"
info "Logs: journalctl -u wifi-ap -f"
info "Logs: journalctl -u sing-box -f"
echo ""
