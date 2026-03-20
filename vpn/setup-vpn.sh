#!/bin/bash
# =============================================================================
# setup-vpn.sh — настройка WireGuard конфигурации
# Валидирует, копирует и активирует конфиг WireGuard
# =============================================================================

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

WG_CONFIG="${WG_CONFIG:-/etc/wireguard/wg0.conf}"
VPN_IFACE="${VPN_IFACE:-wg0}"
LOG_TAG="${LOG_TAG:-ltemod}"

TEMPLATE_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_FILE="$TEMPLATE_DIR/wg0.conf.template"

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    log_err "This script must be run as root"
    exit 1
fi

# Найти конфиг для установки (аргумент или рядом с шаблоном)
INPUT_CONF="${1:-}"
if [[ -z "$INPUT_CONF" ]]; then
    # Попробовать wg0.conf рядом с шаблоном
    candidate="$TEMPLATE_DIR/wg0.conf"
    if [[ -f "$candidate" ]]; then
        INPUT_CONF="$candidate"
    else
        log_err "No WireGuard config provided."
        echo ""
        echo "Usage: $0 /path/to/wg0.conf"
        echo ""
        echo "Or create wg0.conf based on the template:"
        echo "  cp $TEMPLATE_FILE $TEMPLATE_DIR/wg0.conf"
        echo "  # Edit wg0.conf and fill in YOUR_* placeholders"
        echo "  sudo $0"
        exit 1
    fi
fi

log "Using config: $INPUT_CONF"

# Проверить что файл существует
if [[ ! -f "$INPUT_CONF" ]]; then
    log_err "Config file not found: $INPUT_CONF"
    exit 1
fi

# Проверить что плейсхолдеры заменены
placeholders=()
while IFS= read -r line; do
    if echo "$line" | grep -qE "YOUR_[A-Z_]+"; then
        placeholder=$(echo "$line" | grep -oE "YOUR_[A-Z_]+" | head -1)
        placeholders+=("$placeholder")
    fi
done < "$INPUT_CONF"

if [[ ${#placeholders[@]} -gt 0 ]]; then
    log_err "Config still contains unfilled placeholders:"
    for p in "${placeholders[@]}"; do
        echo "  - $p"
    done
    echo ""
    echo "Edit $INPUT_CONF and replace all YOUR_* values with real data."
    exit 1
fi

# Базовая валидация синтаксиса
if ! grep -q "^\[Interface\]" "$INPUT_CONF"; then
    log_err "Invalid WireGuard config: missing [Interface] section"
    exit 1
fi
if ! grep -q "^\[Peer\]" "$INPUT_CONF"; then
    log_err "Invalid WireGuard config: missing [Peer] section"
    exit 1
fi
if ! grep -q "^PrivateKey" "$INPUT_CONF"; then
    log_err "Invalid WireGuard config: missing PrivateKey"
    exit 1
fi

log "Config validation passed"

# Создать директорию
mkdir -p /etc/wireguard

# Если WireGuard уже запущен — остановить
if ip link show "$VPN_IFACE" &>/dev/null; then
    log "Stopping existing WireGuard interface $VPN_IFACE..."
    wg-quick down "$VPN_IFACE" 2>/dev/null || true
fi

# Скопировать конфиг с правильными правами
log "Installing config to $WG_CONFIG..."
cp "$INPUT_CONF" "$WG_CONFIG"
chmod 600 "$WG_CONFIG"
chown root:root "$WG_CONFIG"

log "WireGuard config installed successfully"
echo ""
echo "Next steps:"
echo "  sudo vpn-toggle.sh on    # Enable VPN (route traffic through WireGuard)"
echo "  sudo vpn-toggle.sh off   # Disable VPN (use direct LTE)"
echo "  sudo vpn-toggle.sh status # Show current mode"
echo ""
echo "To auto-start VPN on boot:"
echo "  sudo systemctl enable wg-quick@${VPN_IFACE}.service"
