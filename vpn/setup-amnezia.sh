#!/bin/bash
# =============================================================================
# setup-amnezia.sh — установка конфига AmneziaWG
#
# Использование:
#   sudo setup-amnezia /path/to/awg0.conf
# =============================================================================

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

AMNEZIA_CONFIG="${AMNEZIA_CONFIG:-/etc/amnezia/amneziawg/awg0.conf}"
AMNEZIA_IFACE="${AMNEZIA_IFACE:-awg0}"
LOG_TAG="${LOG_TAG:-ltemod}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
fail()    { echo -e "  ${RED}✗${NC} $*"; exit 1; }
info()    { echo -e "  ${YELLOW}→${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
    echo "Must be run as root: sudo $0 /path/to/awg0.conf"
    exit 1
fi

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /path/to/awg0.conf"
    echo ""
    echo "Template: /etc/ltemod/amnezia-wg.conf.template"
    exit 1
fi

SRC_CONF="$1"

if [[ ! -f "$SRC_CONF" ]]; then
    fail "Config file not found: $SRC_CONF"
fi

echo ""
echo "=== AmneziaWG Setup ==="
echo ""

# --- Проверка наличия awg-quick ---
if ! command -v awg-quick &>/dev/null; then
    fail "awg-quick not found. Install AmneziaWG first:
  See: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module
  Or run: sudo bash install.sh (включает установку AmneziaWG)"
fi
ok "awg-quick found: $(command -v awg-quick)"

# --- Проверка плейсхолдеров ---
if grep -q "YOUR_" "$SRC_CONF"; then
    echo ""
    echo -e "${RED}ERROR:${NC} Config contains unfilled placeholders:"
    grep "YOUR_" "$SRC_CONF" | head -10
    echo ""
    fail "Fill in all YOUR_* values before installing"
fi
ok "No unfilled placeholders"

# --- Проверка обязательных полей ---
if ! grep -q "^\[Interface\]" "$SRC_CONF"; then
    fail "Missing [Interface] section"
fi
if ! grep -q "^PrivateKey\s*=" "$SRC_CONF"; then
    fail "Missing PrivateKey in [Interface]"
fi
if ! grep -q "^\[Peer\]" "$SRC_CONF"; then
    fail "Missing [Peer] section"
fi
if ! grep -q "^PublicKey\s*=" "$SRC_CONF"; then
    fail "Missing PublicKey in [Peer]"
fi
ok "Config structure valid"

# --- Проверка параметров обфускации AmneziaWG ---
if ! grep -q "^Jc\s*=" "$SRC_CONF"; then
    info "Warning: No Jc parameter found — this may be a plain WireGuard config"
    info "AmneziaWG requires Jc, Jmin, Jmax parameters for obfuscation"
fi

# --- Остановить текущий awg интерфейс если запущен ---
if ip link show "$AMNEZIA_IFACE" &>/dev/null; then
    info "Stopping existing $AMNEZIA_IFACE..."
    awg-quick down "$AMNEZIA_IFACE" 2>/dev/null || \
        ip link delete "$AMNEZIA_IFACE" 2>/dev/null || true
fi

# --- Создать директорию ---
mkdir -p "$(dirname "$AMNEZIA_CONFIG")"
chmod 700 "$(dirname "$AMNEZIA_CONFIG")"

# --- Установить конфиг ---
install -m 600 "$SRC_CONF" "$AMNEZIA_CONFIG"
ok "Config installed: $AMNEZIA_CONFIG"

# Сохранить имя интерфейса в конфиге ltemod
# (awg-quick использует имя файла без расширения как имя интерфейса)
IFACE_NAME=$(basename "$AMNEZIA_CONFIG" .conf)
ok "Interface will be: $IFACE_NAME"

echo ""
echo "=== AmneziaWG config installed ==="
echo ""
info "To enable: sudo vpn-toggle amnezia on"
info "To test:   awg-quick up $IFACE_NAME && awg show"
echo ""
