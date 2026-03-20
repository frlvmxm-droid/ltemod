#!/bin/bash
# =============================================================================
# install.sh — установка ltemod на Orange Pi 3 LTS (Armbian)
# Sierra Wireless EM7565 + WireGuard VPN роутер
#
# Использование:
#   sudo bash install.sh
# =============================================================================

set -euo pipefail

# Цвета
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

# Пути установки
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

# Проверить ОС
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    info "OS: $PRETTY_NAME"
fi

# Проверить архитектуру (Orange Pi 3 LTS: aarch64)
arch=$(uname -m)
info "Architecture: $arch"

# Проверить что это не запуск поверх существующей рабочей конфигурации
if systemctl is-active --quiet lte-modem.service 2>/dev/null; then
    echo ""
    echo -e "${YELLOW}WARNING:${NC} lte-modem.service is currently active."
    read -r -p "Reinstall and restart services? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ===== Установка пакетов =====

header "Installing required packages"

# Обновить список пакетов
info "Updating package lists..."
apt-get update -qq || info "apt-get update failed (continuing anyway)"

PACKAGES=(
    modemmanager          # ModemManager для управления модемом
    libmbim-utils         # MBIM утилиты (mbimcli)
    libqmi-utils          # QMI утилиты (qmicli, qmi-network)
    wireguard-tools       # wg, wg-quick
    iptables              # iptables
    iptables-persistent   # Сохранение iptables правил
    network-manager       # NetworkManager + nmcli
    isc-dhcp-client       # dhclient (запасной DHCP клиент)
    usb-modeswitch        # Переключение режимов USB-модемов
    pciutils              # lsusb и утилиты для USB
    usbutils              # lsusb
)

info "Installing: ${PACKAGES[*]}"

# Отключить интерактивный ввод при установке iptables-persistent
export DEBIAN_FRONTEND=noninteractive
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections

apt-get install -y "${PACKAGES[@]}" || {
    fail "Some packages failed to install"
    info "Trying to continue..."
}
ok "Packages installed"

# ===== Загрузка модулей ядра =====

header "Loading kernel modules"

modules=(wireguard cdc_mbim qmi_wwan cdc_acm cdc_wdm)
for mod in "${modules[@]}"; do
    if modprobe "$mod" 2>/dev/null; then
        ok "Module $mod loaded"
    else
        info "Module $mod: not available (may not be needed)"
    fi
done

# Добавить в автозагрузку
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
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

ok "Directories created"

# ===== Копирование файлов =====

header "Installing scripts"

# Скрипты модема
install -m 755 "$SCRIPT_DIR/modem/connect-modem.sh"   "$INSTALL_BIN/connect-modem.sh"
install -m 755 "$SCRIPT_DIR/modem/modem-status.sh"    "$INSTALL_BIN/modem-status.sh"
install -m 755 "$SCRIPT_DIR/modem/modem-watchdog.sh"  "$INSTALL_BIN/modem-watchdog.sh"

# Сетевые скрипты
install -m 755 "$SCRIPT_DIR/network/setup-routing.sh" "$INSTALL_BIN/setup-routing.sh"
install -m 755 "$SCRIPT_DIR/network/vpn-toggle.sh"    "$INSTALL_BIN/vpn-toggle.sh"

# VPN скрипты
install -m 755 "$SCRIPT_DIR/vpn/setup-vpn.sh"         "$INSTALL_BIN/setup-vpn.sh"

ok "Scripts installed to $INSTALL_BIN"

# Симлинки для удобного вызова из PATH
for cmd in vpn-toggle.sh modem-status.sh setup-vpn.sh; do
    target="/usr/local/bin/${cmd%.sh}"
    if [[ ! -e "$target" ]]; then
        ln -sf "$INSTALL_BIN/$cmd" "$target"
        ok "Symlink: $target → $INSTALL_BIN/$cmd"
    fi
done
# vpn-toggle без суффикса
ln -sf "$INSTALL_BIN/vpn-toggle.sh" /usr/local/bin/vpn-toggle 2>/dev/null || true

# Шаблон WireGuard
install -m 644 "$SCRIPT_DIR/vpn/wg0.conf.template" "$INSTALL_CONF/wg0.conf.template"
ok "WireGuard template installed to $INSTALL_CONF/wg0.conf.template"

# ===== Конфигурация =====

header "Installing configuration"

if [[ -f "$INSTALL_CONF/ltemod.conf" ]]; then
    info "Config already exists at $INSTALL_CONF/ltemod.conf — keeping existing"
    info "New template saved as $INSTALL_CONF/ltemod.conf.new"
    install -m 640 "$SCRIPT_DIR/config/ltemod.conf" "$INSTALL_CONF/ltemod.conf.new"
else
    install -m 640 "$SCRIPT_DIR/config/ltemod.conf" "$INSTALL_CONF/ltemod.conf"
    ok "Config installed to $INSTALL_CONF/ltemod.conf"
fi

# Обновить EnvironmentFile в скриптах (они используют /etc/ltemod/ltemod.conf)
ok "Configuration ready"

# ===== udev правила =====

header "Installing udev rules"

install -m 644 "$SCRIPT_DIR/modem/99-em7565.rules" \
    "$INSTALL_UDEV/99-em7565.rules"
ok "udev rules installed"

udevadm control --reload-rules
udevadm trigger --subsystem-match=usb 2>/dev/null || true
ok "udev rules reloaded"

# ===== sysctl =====

header "Configuring sysctl"

cat > "$INSTALL_SYSCTL/99-ltemod.conf" <<'EOF'
# ltemod: IP forwarding for LTE router
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF

sysctl -p "$INSTALL_SYSCTL/99-ltemod.conf" > /dev/null 2>&1 || true
ok "IP forwarding enabled"

# ===== systemd сервисы =====

header "Installing systemd services"

install -m 644 "$SCRIPT_DIR/systemd/lte-modem.service"    "$INSTALL_SYSTEMD/lte-modem.service"
install -m 644 "$SCRIPT_DIR/systemd/lte-watchdog.service" "$INSTALL_SYSTEMD/lte-watchdog.service"
install -m 644 "$SCRIPT_DIR/systemd/lte-watchdog.timer"   "$INSTALL_SYSTEMD/lte-watchdog.timer"
ok "Systemd units installed"

systemctl daemon-reload
ok "systemd daemon reloaded"

systemctl enable lte-watchdog.timer
ok "lte-watchdog.timer enabled"

# lte-modem.service запускается через udev при подключении модема
# Но также можно включить для запуска при старте если модем уже подключён
systemctl enable lte-modem.service
ok "lte-modem.service enabled"

# ===== Итог =====

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      Installation Complete!                  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "Next steps:"
echo ""
echo -e "  ${YELLOW}1. Edit configuration:${NC}"
echo "     sudo nano /etc/ltemod/ltemod.conf"
echo "     → Set APN for your carrier"
echo "     → Set LAN_IFACE (check with: ip link)"
echo ""
echo -e "  ${YELLOW}2. Setup WireGuard (optional):${NC}"
echo "     cp $INSTALL_CONF/wg0.conf.template /tmp/wg0.conf"
echo "     nano /tmp/wg0.conf  # Fill in YOUR_* placeholders"
echo "     sudo setup-vpn /tmp/wg0.conf"
echo ""
echo -e "  ${YELLOW}3. Connect modem and start:${NC}"
echo "     sudo systemctl start lte-modem.service"
echo ""
echo -e "  ${YELLOW}4. Check status:${NC}"
echo "     sudo modem-status"
echo ""
echo -e "  ${YELLOW}5. Toggle VPN:${NC}"
echo "     sudo vpn-toggle on    # Enable VPN"
echo "     sudo vpn-toggle off   # Direct LTE (default)"
echo "     vpn-toggle status     # Show mode"
echo ""
info "Logs: journalctl -u lte-modem -f"
info "Logs: journalctl -u lte-watchdog -f"
echo ""
