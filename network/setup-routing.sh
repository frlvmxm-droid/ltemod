#!/bin/bash
# =============================================================================
# setup-routing.sh — базовая настройка маршрутизации
# Режим по умолчанию: прямой LTE (без VPN)
# Вызывается из lte-modem.service после успешного подключения модема
# =============================================================================

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

WWAN_IFACE="${WWAN_IFACE:-wwan0}"
LAN_IFACE="${LAN_IFACE:-end0}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/ltemod}"
MODE_FILE="${MODE_FILE:-/run/ltemod/mode}"
LOG_TAG="${LOG_TAG:-ltemod}"

log() {
    logger -t "$LOG_TAG" "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
    logger -t "$LOG_TAG" -p user.err "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

if [[ $EUID -ne 0 ]]; then
    log_err "Must be run as root"
    exit 1
fi

# Создать runtime директорию
mkdir -p "$RUNTIME_DIR"

log "=== Setting up routing (direct LTE mode) ==="

# --- IP Forwarding ---
log "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1 || true

# Сохранить в sysctl.d для персистентности
SYSCTL_CONF="/etc/sysctl.d/99-ltemod.conf"
if [[ ! -f "$SYSCTL_CONF" ]]; then
    cat > "$SYSCTL_CONF" <<EOF
# ltemod: IP forwarding for LTE router
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
    log "Created $SYSCTL_CONF"
fi

# --- Ждать появления WWAN интерфейса ---
timeout=30
elapsed=0
while ! ip link show "$WWAN_IFACE" &>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [[ $elapsed -ge $timeout ]]; then
        log_err "WWAN interface $WWAN_IFACE not found after ${timeout}s"
        log_err "Check modem connection and WWAN_IFACE setting in ltemod.conf"
        exit 1
    fi
done

# --- iptables NAT: прямой LTE режим ---
log "Configuring iptables for direct LTE routing..."

# Очистить старые MASQUERADE правила ltemod (через comment mark)
iptables -t nat -L POSTROUTING --line-numbers -n 2>/dev/null | \
    grep -E "MASQUERADE" | awk '{print $1}' | sort -rn | \
    while read -r num; do iptables -t nat -D POSTROUTING "$num" 2>/dev/null || true; done

# MASQUERADE для исходящего трафика через LTE интерфейс
if ! iptables -t nat -C POSTROUTING -o "$WWAN_IFACE" -j MASQUERADE &>/dev/null; then
    iptables -t nat -A POSTROUTING -o "$WWAN_IFACE" -j MASQUERADE
    log "Added MASQUERADE rule for $WWAN_IFACE"
fi

# FORWARD: разрешить трафик LAN → WAN (LTE)
if ! iptables -C FORWARD -i "$LAN_IFACE" -o "$WWAN_IFACE" -j ACCEPT &>/dev/null; then
    iptables -A FORWARD -i "$LAN_IFACE" -o "$WWAN_IFACE" -j ACCEPT
fi

# FORWARD: разрешить ответный трафик WAN → LAN
if ! iptables -C FORWARD -i "$WWAN_IFACE" -o "$LAN_IFACE" \
        -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
    iptables -A FORWARD -i "$WWAN_IFACE" -o "$LAN_IFACE" \
        -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

# --- Сохранить текущий режим ---
echo "direct" > "$MODE_FILE"
log "Routing mode set to: direct (LTE)"

log "=== Routing setup complete ==="
log "LAN ($LAN_IFACE) → LTE ($WWAN_IFACE) → Internet"
log "Use 'vpn-toggle.sh on' to enable VPN mode"
