#!/bin/bash
# =============================================================================
# setup-desync.sh — TCP desynchronization / DPI bypass
#
# Applies iptables-based techniques to evade deep packet inspection.
# No external binary required for mss/rst-drop modes; nfqws mode uses
# nfqws from the zapret project (downloaded automatically if absent).
#
# Config vars in /etc/ltemod/ltemod.conf:
#   DESYNC_ENABLED="yes|no"            — master switch (default: yes)
#   DESYNC_MODE="mss|rst-drop|nfqws|auto"  — mode (default: auto)
#   DESYNC_PORTS="443,80"             — ports to intercept
#   DESYNC_MSS=40                     — MSS value for mss mode
#   DESYNC_TTL=8                      — TTL for fake packets (nfqws)
#   DESYNC_SPLIT_POS=2                — split position (nfqws)
#   DESYNC_FAKE_SNI="www.google.com"  — fake SNI (nfqws)
#   DESYNC_IFACE=""                   — WAN iface (empty = auto-detect)
#
# Runtime state: /run/ltemod/desync_mode
#
# Usage:
#   setup-desync.sh start   — apply rules from config
#   setup-desync.sh stop    — remove all ltemod desync rules
#   setup-desync.sh status  — show active mode and installed rules
#   setup-desync.sh test    — check whether rules are installed
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ---------------------------------------------------------------------------
# Defaults (all overridable from ltemod.conf)
# ---------------------------------------------------------------------------
DESYNC_ENABLED="${DESYNC_ENABLED:-yes}"
DESYNC_MODE="${DESYNC_MODE:-auto}"
DESYNC_PORTS="${DESYNC_PORTS:-443,80}"
DESYNC_MSS="${DESYNC_MSS:-40}"
DESYNC_TTL="${DESYNC_TTL:-8}"
DESYNC_SPLIT_POS="${DESYNC_SPLIT_POS:-2}"
DESYNC_FAKE_SNI="${DESYNC_FAKE_SNI:-www.google.com}"
DESYNC_IFACE="${DESYNC_IFACE:-}"

RUNTIME_DIR="${RUNTIME_DIR:-/run/ltemod}"
STATE_FILE="$RUNTIME_DIR/desync_mode"
NFQWS_PID_FILE="$RUNTIME_DIR/nfqws.pid"
NFQWS_BIN="${NFQWS_BIN:-/usr/local/bin/nfqws}"
NFQUEUE_NUM=200
CHAIN="LTEMOD_DESYNC"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    logger -t ltemod-desync "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
    logger -t ltemod-desync -p user.err "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log_warn() {
    logger -t ltemod-desync -p user.warning "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    log_err "Must be run as root"
    exit 1
fi

mkdir -p "$RUNTIME_DIR"

# Auto-detect WAN interface from the default route.
get_wan_iface() {
    ip route show default | awk '/default/{print $5; exit}'
}

resolve_iface() {
    local iface="${DESYNC_IFACE:-}"
    if [[ -z "$iface" ]]; then
        iface=$(get_wan_iface)
    fi
    if [[ -z "$iface" ]]; then
        log_err "Cannot determine WAN interface (no default route?)"
        exit 1
    fi
    echo "$iface"
}

# ---------------------------------------------------------------------------
# iptables chain management (mangle table, POSTROUTING)
# ---------------------------------------------------------------------------

ensure_chain() {
    if ! iptables -t mangle -L "$CHAIN" -n &>/dev/null; then
        iptables -t mangle -N "$CHAIN"
        log "Created chain $CHAIN in mangle table"
    fi

    if ! iptables -t mangle -C POSTROUTING -j "$CHAIN" &>/dev/null 2>&1; then
        iptables -t mangle -A POSTROUTING -j "$CHAIN"
        log "Added -A POSTROUTING -j $CHAIN"
    fi
}

flush_chain() {
    ensure_chain
    iptables -t mangle -F "$CHAIN"
    log "Flushed chain $CHAIN"
}

delete_chain() {
    # Remove POSTROUTING → chain jump (may not exist — ignore errors)
    iptables -t mangle -D POSTROUTING -j "$CHAIN" 2>/dev/null || true
    # Flush then delete
    iptables -t mangle -F "$CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$CHAIN" 2>/dev/null || true
    log "Removed chain $CHAIN from mangle table"
}

# ---------------------------------------------------------------------------
# nfqws lifecycle
# ---------------------------------------------------------------------------

nfqws_is_running() {
    [[ -f "$NFQWS_PID_FILE" ]] || return 1
    local pid
    pid=$(cat "$NFQWS_PID_FILE" 2>/dev/null) || return 1
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

stop_nfqws() {
    if [[ -f "$NFQWS_PID_FILE" ]]; then
        local pid
        pid=$(cat "$NFQWS_PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null && log "Stopped nfqws (pid $pid)" || \
                log_warn "Could not kill nfqws pid $pid"
        fi
        rm -f "$NFQWS_PID_FILE"
    fi
}

# Download nfqws for the current CPU architecture.
download_nfqws() {
    local raw_arch
    raw_arch=$(uname -m)
    local arch
    case "$raw_arch" in
        aarch64|arm64) arch="aarch64" ;;
        armv7*|armhf)  arch="arm"     ;;
        x86_64)        arch="x86_64"  ;;
        *)
            log_err "Unsupported architecture for nfqws auto-download: $raw_arch"
            return 1
            ;;
    esac

    local url="https://github.com/bol-van/zapret/releases/latest/download/nfqws-linux-${arch}"
    log "Downloading nfqws from $url ..."

    if command -v curl &>/dev/null; then
        curl -fsSL -o "$NFQWS_BIN" "$url" || { log_err "curl download failed"; return 1; }
    elif command -v wget &>/dev/null; then
        wget -qO "$NFQWS_BIN" "$url" || { log_err "wget download failed"; return 1; }
    else
        log_err "Neither curl nor wget found — cannot download nfqws"
        return 1
    fi

    chmod 755 "$NFQWS_BIN"
    log "nfqws installed to $NFQWS_BIN"
}

ensure_nfqws() {
    if command -v nfqws &>/dev/null; then
        NFQWS_BIN=$(command -v nfqws)
        return 0
    fi
    if [[ -x "$NFQWS_BIN" ]]; then
        return 0
    fi
    log "nfqws not found — attempting download..."
    download_nfqws
}

# ---------------------------------------------------------------------------
# Mode: mss
# Clamp MSS for TCP SYN packets on target ports, forcing TLS ClientHello
# fragmentation across multiple TCP segments.
# ---------------------------------------------------------------------------
apply_mss() {
    local iface="$1"
    ensure_chain
    flush_chain

    iptables -t mangle -A "$CHAIN" \
        -o "$iface" -p tcp --tcp-flags SYN,RST SYN \
        -m multiport --dports "$DESYNC_PORTS" \
        -j TCPMSS --set-mss "$DESYNC_MSS"

    log "mss: set MSS=$DESYNC_MSS on ports $DESYNC_PORTS via $iface"
}

# ---------------------------------------------------------------------------
# Mode: rst-drop
# Drop forged RST packets injected by DPI middleboxes (INVALID conntrack state).
# Inserted at the top of INPUT — no custom chain needed.
# ---------------------------------------------------------------------------
apply_rst_drop() {
    local iface="$1"

    # Idempotent: check before inserting
    if ! iptables -C INPUT \
            -i "$iface" -p tcp \
            -m conntrack --ctstate INVALID \
            --tcp-flags RST RST -j DROP &>/dev/null 2>&1; then
        iptables -I INPUT \
            -i "$iface" -p tcp \
            -m conntrack --ctstate INVALID \
            --tcp-flags RST RST -j DROP
        log "rst-drop: inserted DROP INVALID RST rule on $iface INPUT"
    else
        log "rst-drop: DROP INVALID RST rule already present on $iface"
    fi
}

remove_rst_drop() {
    local iface="$1"
    # Remove all matching rules (loop in case inserted multiple times)
    while iptables -D INPUT \
            -i "$iface" -p tcp \
            -m conntrack --ctstate INVALID \
            --tcp-flags RST RST -j DROP 2>/dev/null; do
        log "rst-drop: removed DROP INVALID RST rule from INPUT ($iface)"
    done
}

# ---------------------------------------------------------------------------
# Mode: nfqws
# Full DPI bypass via nfqws (zapret project).  The NFQUEUE rule intercepts
# the first 6 packets of each new TCP connection; nfqws modifies them.
# ---------------------------------------------------------------------------
apply_nfqws() {
    local iface="$1"

    ensure_nfqws || {
        log_err "nfqws not available — cannot apply nfqws mode"
        return 1
    }

    ensure_chain
    flush_chain

    iptables -t mangle -A "$CHAIN" \
        -o "$iface" -p tcp \
        -m multiport --dports "$DESYNC_PORTS" \
        -m connbytes --connbytes-dir=original --connbytes-mode=packets \
        --connbytes 1:6 \
        -j NFQUEUE --queue-num "$NFQUEUE_NUM" --queue-bypass

    log "nfqws: NFQUEUE rule installed (queue $NFQUEUE_NUM, ports $DESYNC_PORTS, iface $iface)"

    # Stop any previous instance
    stop_nfqws

    # Launch nfqws in background
    "$NFQWS_BIN" \
        --qnum="$NFQUEUE_NUM" \
        --dpi-desync=fake \
        --dpi-desync-ttl="$DESYNC_TTL" \
        --dpi-desync-fake-tls="$DESYNC_FAKE_SNI" \
        &

    local pid=$!
    echo "$pid" > "$NFQWS_PID_FILE"
    log "nfqws started (pid $pid, ttl=$DESYNC_TTL, split=$DESYNC_SPLIT_POS, sni=$DESYNC_FAKE_SNI)"
}

# ---------------------------------------------------------------------------
# Mode: auto
# Use nfqws if available, otherwise fall back to mss + rst-drop.
# ---------------------------------------------------------------------------
apply_auto() {
    local iface="$1"

    if command -v nfqws &>/dev/null || [[ -x "$NFQWS_BIN" ]]; then
        log "auto: nfqws found — using nfqws mode"
        apply_nfqws "$iface"
        echo "nfqws" > "$STATE_FILE"
    else
        # Try to download nfqws; if that also fails, fall back gracefully
        if download_nfqws 2>/dev/null; then
            log "auto: nfqws downloaded — using nfqws mode"
            apply_nfqws "$iface"
            echo "nfqws" > "$STATE_FILE"
        else
            log "auto: nfqws unavailable — falling back to mss+rst-drop"
            apply_mss "$iface"
            apply_rst_drop "$iface"
            echo "mss+rst-drop" > "$STATE_FILE"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Command: start
# ---------------------------------------------------------------------------
cmd_start() {
    if [[ "$DESYNC_ENABLED" != "yes" ]]; then
        log "DESYNC_ENABLED is not 'yes' — skipping"
        echo "off" > "$STATE_FILE"
        return 0
    fi

    local iface
    iface=$(resolve_iface)
    log "=== Starting DPI desync (mode=$DESYNC_MODE, iface=$iface) ==="

    case "$DESYNC_MODE" in
        mss)
            apply_mss "$iface"
            echo "mss" > "$STATE_FILE"
            ;;
        rst-drop)
            apply_rst_drop "$iface"
            echo "rst-drop" > "$STATE_FILE"
            ;;
        nfqws)
            apply_nfqws "$iface"
            echo "nfqws" > "$STATE_FILE"
            ;;
        auto)
            apply_auto "$iface"
            ;;
        *)
            log_err "Unknown DESYNC_MODE: '$DESYNC_MODE' — must be mss, rst-drop, nfqws, or auto"
            exit 1
            ;;
    esac

    local active_mode
    active_mode=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
    log "=== Desync started: active mode = $active_mode ==="
}

# ---------------------------------------------------------------------------
# Command: stop
# ---------------------------------------------------------------------------
cmd_stop() {
    log "=== Stopping DPI desync ==="

    # Determine interface to clean up rst-drop rule
    local iface
    iface=$(resolve_iface 2>/dev/null || true)

    # 1. Kill nfqws if running
    stop_nfqws

    # 2. Flush and remove the mangle chain
    delete_chain

    # 3. Remove rst-drop INPUT rule (best-effort — try all plausible ifaces)
    if [[ -n "$iface" ]]; then
        remove_rst_drop "$iface"
    fi
    # Also try to remove any rst-drop rules on any iface (belt-and-suspenders)
    while iptables -D INPUT \
            -p tcp \
            -m conntrack --ctstate INVALID \
            --tcp-flags RST RST -j DROP 2>/dev/null; do
        log "rst-drop: removed a wildcard DROP INVALID RST rule"
    done

    echo "off" > "$STATE_FILE"
    log "=== Desync stopped ==="
}

# ---------------------------------------------------------------------------
# Command: status
# ---------------------------------------------------------------------------
cmd_status() {
    echo "=== Desync Status ==="
    echo ""

    # Active mode from state file
    local active="off"
    if [[ -f "$STATE_FILE" ]]; then
        active=$(cat "$STATE_FILE")
    fi
    echo "  Active mode:       $active"
    echo "  DESYNC_ENABLED:    $DESYNC_ENABLED"
    echo "  DESYNC_MODE:       $DESYNC_MODE"
    echo "  DESYNC_PORTS:      $DESYNC_PORTS"
    echo "  DESYNC_MSS:        $DESYNC_MSS"
    echo "  DESYNC_TTL:        $DESYNC_TTL"
    echo "  DESYNC_FAKE_SNI:   $DESYNC_FAKE_SNI"

    local iface
    iface=$(resolve_iface 2>/dev/null || echo "(unknown)")
    echo "  WAN interface:     $iface"
    echo ""

    # nfqws status
    if nfqws_is_running; then
        local pid
        pid=$(cat "$NFQWS_PID_FILE" 2>/dev/null)
        echo "  nfqws:             running (pid $pid)"
    else
        echo "  nfqws:             not running"
    fi
    echo ""

    # Show mangle chain rules
    echo "  mangle $CHAIN chain:"
    if iptables -t mangle -L "$CHAIN" -n --line-numbers 2>/dev/null; then
        :
    else
        echo "    (chain does not exist)"
    fi
    echo ""

    # Show relevant INPUT rules
    echo "  INPUT rst-drop rules:"
    if iptables -L INPUT -n --line-numbers 2>/dev/null | grep -E "INVALID.*RST|RST.*INVALID"; then
        :
    else
        echo "    (none)"
    fi
}

# ---------------------------------------------------------------------------
# Command: test
# ---------------------------------------------------------------------------
cmd_test() {
    local ok=0

    local active="off"
    [[ -f "$STATE_FILE" ]] && active=$(cat "$STATE_FILE")

    if [[ "$active" == "off" ]]; then
        echo "RESULT: Desync is OFF (state file: $active)"
        return 1
    fi

    echo "=== Desync Test ==="
    echo "  State file mode: $active"

    case "$active" in
        mss|nfqws|mss+rst-drop)
            if iptables -t mangle -L "$CHAIN" -n 2>/dev/null | grep -qv "^Chain\|^target\|^$"; then
                echo "  PASS: $CHAIN chain has rules"
                ok=$((ok + 1))
            else
                echo "  FAIL: $CHAIN chain is empty or missing"
            fi
            ;;
    esac

    case "$active" in
        rst-drop|mss+rst-drop)
            if iptables -L INPUT -n 2>/dev/null | grep -qE "INVALID.*RST|RST.*INVALID"; then
                echo "  PASS: rst-drop INPUT rule present"
                ok=$((ok + 1))
            else
                echo "  FAIL: rst-drop INPUT rule missing"
            fi
            ;;
    esac

    if [[ "$active" == "nfqws" ]]; then
        if nfqws_is_running; then
            echo "  PASS: nfqws is running (pid $(cat "$NFQWS_PID_FILE"))"
            ok=$((ok + 1))
        else
            echo "  FAIL: nfqws is not running"
        fi
    fi

    echo ""
    if [[ $ok -gt 0 ]]; then
        echo "RESULT: Rules appear installed (checks passed: $ok)"
        return 0
    else
        echo "RESULT: No desync rules detected"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
    start)  cmd_start  ;;
    stop)   cmd_stop   ;;
    status) cmd_status ;;
    test)   cmd_test   ;;
    *)
        echo "Usage: $0 {start|stop|status|test}"
        exit 1
        ;;
esac
