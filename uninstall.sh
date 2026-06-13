#!/bin/bash
# =============================================================================
# uninstall.sh — удаление ltemod
#
#   sudo bash uninstall.sh           — удалить скрипты и сервисы, СОХРАНИТЬ конфиги
#   sudo bash uninstall.sh --purge   — удалить всё, включая /etc/ltemod (профили,
#                                      пароли, активный профиль)
#
# Self-contained: пути захардкожены, репозиторий не требуется.
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()     { echo -e "${GREEN}✓${NC} $*"; }
info()   { echo -e "${YELLOW}→${NC} $*"; }
header() { echo -e "\n${CYAN}=== $* ===${NC}"; }

INSTALL_BIN="/usr/local/bin/ltemod"
INSTALL_CONF="/etc/ltemod"
INSTALL_SYSTEMD="/etc/systemd/system"

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR:${NC} run as root: sudo bash $0 ${1:-}" >&2
    exit 1
fi

echo -e "${CYAN}ltemod uninstaller${NC}"
[[ $PURGE -eq 1 ]] && info "Mode: PURGE (конфиги и профили будут удалены)" \
                   || info "Mode: keep configs (/etc/ltemod сохраняется; --purge чтобы удалить)"
read -r -p "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
header "Stopping runtime (clean routes/iptables)"
# Снять VPN и kill-switch, остановить AP — чтобы убрать динамические правила
[[ -x "$INSTALL_BIN/vpn-toggle.sh" ]] && bash "$INSTALL_BIN/vpn-toggle.sh" off &>/dev/null || true
[[ -x "$INSTALL_BIN/setup-ap.sh" ]]   && bash "$INSTALL_BIN/setup-ap.sh" stop &>/dev/null || true
ok "VPN/AP stopped (best-effort)"

# ---------------------------------------------------------------------------
header "Disabling and removing systemd units"
UNITS=(lte-modem.service lte-watchdog.timer lte-watchdog.service wifi-ap.service sing-box.service)
for u in "${UNITS[@]}"; do
    systemctl stop "$u" &>/dev/null || true
    systemctl disable "$u" &>/dev/null || true
    if [[ -f "$INSTALL_SYSTEMD/$u" ]]; then
        rm -f "$INSTALL_SYSTEMD/$u"
        ok "Removed unit: $u"
    fi
done
systemctl daemon-reload
ok "systemd reloaded"

# ---------------------------------------------------------------------------
header "Removing symlinks"
for cmd in vpn-toggle modem-status setup-vpn setup-amnezia setup-vless setup-ap \
           setup-wifi-client detect-hardware ltemod-doctor vpn-profile killswitch \
           data-usage sms; do
    if [[ -L "/usr/local/bin/$cmd" ]]; then
        rm -f "/usr/local/bin/$cmd"
        ok "Removed symlink: $cmd"
    fi
done

# ---------------------------------------------------------------------------
header "Removing scripts and system config"
[[ -d "$INSTALL_BIN" ]] && { rm -rf "$INSTALL_BIN"; ok "Removed $INSTALL_BIN"; }

rm -f /etc/sysctl.d/99-ltemod.conf                  && ok "Removed sysctl drop-in" || true
rm -f /etc/NetworkManager/conf.d/10-wifi-ap.conf \
      /etc/NetworkManager/conf.d/99-ltemod-unmanaged.conf && ok "Removed NM drop-ins" || true
rm -f /etc/udev/rules.d/99-em7565.rules             && ok "Removed udev rule" || true
rm -f /etc/dnsmasq.d/ltemod-ap.conf                 && ok "Removed dnsmasq AP config" || true
rm -f /etc/hostapd/hostapd-2g.conf /etc/hostapd/hostapd-5g.conf && ok "Removed hostapd configs" || true

udevadm control --reload-rules &>/dev/null || true
systemctl reload NetworkManager &>/dev/null || true

# ---------------------------------------------------------------------------
header "Configs"
if [[ $PURGE -eq 1 ]]; then
    [[ -d "$INSTALL_CONF" ]] && { rm -rf "$INSTALL_CONF"; ok "Purged $INSTALL_CONF (configs, profiles)"; }
    info "VPN secrets в /etc/wireguard, /etc/amnezia, /etc/sing-box НЕ тронуты (удалите вручную при необходимости)"
else
    info "Kept $INSTALL_CONF (используйте --purge чтобы удалить конфиги и профили)"
fi

# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}ltemod uninstalled.${NC}"
info "Установленные пакеты (hostapd, dnsmasq, sing-box и т.д.) НЕ удалены."
info "Динамические iptables-правила очищаются при перезагрузке (или вручную)."
info "Рекомендуется перезагрузка: sudo reboot"
