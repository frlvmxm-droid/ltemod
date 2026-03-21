#!/bin/bash
# =============================================================================
# setup-vless.sh — установка конфига VLESS (sing-box)
#
# Использование:
#   sudo setup-vless /path/to/config.json
# =============================================================================

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

VLESS_CONFIG="${VLESS_CONFIG:-/etc/sing-box/config.json}"
LOG_TAG="${LOG_TAG:-ltemod}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
fail()    { echo -e "  ${RED}✗${NC} $*"; exit 1; }
info()    { echo -e "  ${YELLOW}→${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
    echo "Must be run as root: sudo $0 /path/to/config.json"
    exit 1
fi

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /path/to/config.json"
    echo ""
    echo "Template: /etc/ltemod/vless.json.template"
    exit 1
fi

SRC_CONF="$1"

if [[ ! -f "$SRC_CONF" ]]; then
    fail "Config file not found: $SRC_CONF"
fi

echo ""
echo "=== VLESS (sing-box) Setup ==="
echo ""

# --- Проверка наличия sing-box ---
if ! command -v sing-box &>/dev/null; then
    fail "sing-box not found. Run: sudo bash install.sh (включает установку sing-box)"
fi
ok "sing-box found: $(sing-box version | head -1)"

# --- Проверка JSON синтаксиса ---
if command -v jq &>/dev/null; then
    if ! jq --exit-status . "$SRC_CONF" > /dev/null 2>&1; then
        fail "Invalid JSON syntax in $SRC_CONF"
    fi
    ok "JSON syntax valid"
else
    info "jq not found — skipping JSON syntax check"
fi

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
if command -v jq &>/dev/null; then
    # Проверить наличие VLESS outbound
    if ! jq -e '.outbounds[] | select(.type == "vless")' "$SRC_CONF" > /dev/null 2>&1; then
        fail "No VLESS outbound found in config"
    fi
    ok "VLESS outbound found"

    # Проверить наличие TUN inbound
    if ! jq -e '.inbounds[] | select(.type == "tun")' "$SRC_CONF" > /dev/null 2>&1; then
        info "Warning: No TUN inbound — transparent proxy may not work"
    else
        ok "TUN inbound found"
    fi

    # Проверить server
    server=$(jq -r '.outbounds[] | select(.type == "vless") | .server' "$SRC_CONF" 2>/dev/null || echo "")
    if [[ -z "$server" || "$server" == "null" ]]; then
        fail "Missing 'server' in VLESS outbound"
    fi
    info "Server: $server"
fi

# --- Проверить конфиг через sing-box ---
if sing-box check -c "$SRC_CONF" 2>/dev/null; then
    ok "sing-box config check passed"
else
    info "sing-box config check failed or not supported — proceeding anyway"
fi

# --- Остановить текущий sing-box если запущен ---
if systemctl is-active --quiet sing-box 2>/dev/null; then
    info "Stopping sing-box service..."
    systemctl stop sing-box
fi

# --- Создать директорию и установить конфиг ---
mkdir -p "$(dirname "$VLESS_CONFIG")"
install -m 640 "$SRC_CONF" "$VLESS_CONFIG"
ok "Config installed: $VLESS_CONFIG"

# --- Настроить systemd сервис если ещё не установлен ---
if [[ ! -f /etc/systemd/system/sing-box.service ]]; then
    cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box VLESS client (ltemod)
After=network.target
Documentation=https://sing-box.sagernet.org

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    ok "sing-box.service created"
fi

echo ""
echo "=== VLESS (sing-box) config installed ==="
echo ""
info "To enable: sudo vpn-toggle vless on"
info "To test:   systemctl start sing-box && sing-box version"
info "Logs:      journalctl -u sing-box -f"
echo ""
