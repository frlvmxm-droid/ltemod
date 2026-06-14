#!/bin/bash
# =============================================================================
# setup-ddns.sh — Dynamic DNS updater
#
# Config vars in /etc/ltemod/ltemod.conf:
#   DDNS_ENABLED="yes|no"
#   DDNS_PROVIDER="cloudflare|duckdns|noip|freedns"
#   DDNS_DOMAIN="myhost.example.com"   (cloudflare: just the record name, e.g. "home")
#   DDNS_TOKEN="api_token_or_password"
#   DDNS_ZONE_ID="zone_id"             (Cloudflare only)
#   DDNS_USERNAME="username"           (No-IP only)
#
# Runtime state files in /run/ltemod/:
#   ddns_last_ip      — last IP pushed
#   ddns_last_update  — epoch of last push
#   ddns_last_result  — "ok" or error message
#
# Usage:
#   setup-ddns.sh update   — update if IP changed
#   setup-ddns.sh force    — always update
#   setup-ddns.sh status   — print current status
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

DDNS_ENABLED="${DDNS_ENABLED:-no}"
DDNS_PROVIDER="${DDNS_PROVIDER:-}"
DDNS_DOMAIN="${DDNS_DOMAIN:-}"
DDNS_TOKEN="${DDNS_TOKEN:-}"
DDNS_ZONE_ID="${DDNS_ZONE_ID:-}"
DDNS_USERNAME="${DDNS_USERNAME:-}"

RUNTIME_DIR="${RUNTIME_DIR:-/run/ltemod}"
STATE_IP="${RUNTIME_DIR}/ddns_last_ip"
STATE_UPDATE="${RUNTIME_DIR}/ddns_last_update"
STATE_RESULT="${RUNTIME_DIR}/ddns_last_result"

log() {
    logger -t ltemod-ddns "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
    logger -t ltemod-ddns -p user.err "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

set_result() {
    mkdir -p "$RUNTIME_DIR"
    echo "$1" > "$STATE_RESULT"
}

# ---------------------------------------------------------------------------
# WAN IP detection
# 1. Try reading from the active uplink interface
# 2. Fallback: curl api.ipify.org
# ---------------------------------------------------------------------------
get_wan_ip() {
    local iface ip=""

    if [[ -f "${RUNTIME_DIR}/uplink_iface" ]]; then
        iface="$(cat "${RUNTIME_DIR}/uplink_iface" 2>/dev/null || true)"
        if [[ -n "$iface" ]]; then
            ip="$(ip -4 addr show "$iface" 2>/dev/null \
                  | grep -oP '(?<=inet\s)\d+(\.\d+){3}' \
                  | head -n1 || true)"
        fi
    fi

    if [[ -z "$ip" ]]; then
        ip="$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    fi

    if [[ -z "$ip" ]]; then
        log_err "Could not determine WAN IP"
        return 1
    fi

    echo "$ip"
}

# ---------------------------------------------------------------------------
# Provider: Cloudflare
# List A records → find record ID for DDNS_DOMAIN → PATCH with new IP
# ---------------------------------------------------------------------------
provider_cloudflare() {
    local ip="$1"

    if [[ -z "$DDNS_ZONE_ID" || -z "$DDNS_TOKEN" || -z "$DDNS_DOMAIN" ]]; then
        log_err "Cloudflare requires DDNS_ZONE_ID, DDNS_TOKEN, DDNS_DOMAIN"
        return 1
    fi

    local api="https://api.cloudflare.com/client/v4/zones/${DDNS_ZONE_ID}/dns_records"

    # List records to find the ID for DDNS_DOMAIN type A
    local list_resp record_id
    list_resp="$(curl -s --max-time 15 \
        -H "Authorization: Bearer ${DDNS_TOKEN}" \
        -H "Content-Type: application/json" \
        "${api}?type=A&name=${DDNS_DOMAIN}")"

    record_id="$(echo "$list_resp" | grep -oP '"id"\s*:\s*"\K[^"]+' | head -n1 || true)"

    if [[ -z "$record_id" ]]; then
        log_err "Cloudflare: could not find A record for '${DDNS_DOMAIN}'. Response: $list_resp"
        return 1
    fi

    # PATCH the record
    local patch_resp success
    patch_resp="$(curl -s --max-time 15 \
        -X PATCH \
        -H "Authorization: Bearer ${DDNS_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"content\":\"${ip}\"}" \
        "${api}/${record_id}")"

    success="$(echo "$patch_resp" | grep -oP '"success"\s*:\s*\K(true|false)' | head -n1 || true)"

    if [[ "$success" != "true" ]]; then
        log_err "Cloudflare PATCH failed. Response: $patch_resp"
        return 1
    fi

    log "Cloudflare: updated '${DDNS_DOMAIN}' → $ip"
}

# ---------------------------------------------------------------------------
# Provider: DuckDNS
# Domain is the subdomain part only (before .duckdns.org)
# ---------------------------------------------------------------------------
provider_duckdns() {
    local ip="$1"

    if [[ -z "$DDNS_DOMAIN" || -z "$DDNS_TOKEN" ]]; then
        log_err "DuckDNS requires DDNS_DOMAIN and DDNS_TOKEN"
        return 1
    fi

    # Strip .duckdns.org suffix if the user included it
    local subdomain="${DDNS_DOMAIN%.duckdns.org}"

    local resp
    resp="$(curl -s --max-time 15 \
        "https://www.duckdns.org/update?domains=${subdomain}&token=${DDNS_TOKEN}&ip=${ip}")"

    if [[ "$resp" != "OK" ]]; then
        log_err "DuckDNS update failed. Response: $resp"
        return 1
    fi

    log "DuckDNS: updated '${subdomain}' → $ip"
}

# ---------------------------------------------------------------------------
# Provider: No-IP
# Basic Auth: DDNS_USERNAME:DDNS_TOKEN
# ---------------------------------------------------------------------------
provider_noip() {
    local ip="$1"

    if [[ -z "$DDNS_DOMAIN" || -z "$DDNS_TOKEN" || -z "$DDNS_USERNAME" ]]; then
        log_err "No-IP requires DDNS_DOMAIN, DDNS_USERNAME, and DDNS_TOKEN"
        return 1
    fi

    local resp
    resp="$(curl -s --max-time 15 \
        -u "${DDNS_USERNAME}:${DDNS_TOKEN}" \
        "https://dynupdate.no-ip.com/nic/update?hostname=${DDNS_DOMAIN}&myip=${ip}")"

    case "$resp" in
        good*|nochg*)
            log "No-IP: updated '${DDNS_DOMAIN}' → $ip (response: $resp)"
            ;;
        *)
            log_err "No-IP update failed. Response: $resp"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Provider: FreeDNS (afraid.org)
# Uses a per-record update token (no username needed)
# ---------------------------------------------------------------------------
provider_freedns() {
    local ip="$1"

    if [[ -z "$DDNS_TOKEN" ]]; then
        log_err "FreeDNS requires DDNS_TOKEN"
        return 1
    fi

    local resp
    resp="$(curl -s --max-time 15 \
        "https://freedns.afraid.org/dynamic/update.php?${DDNS_TOKEN}&address=${ip}")"

    # FreeDNS returns a line starting with "Updated" on success, or "ERROR" / nothing on failure
    if echo "$resp" | grep -qi "updated\|has not changed"; then
        log "FreeDNS: updated '${DDNS_DOMAIN:-<token>}' → $ip (response: ${resp%%$'\n'*})"
    else
        log_err "FreeDNS update failed. Response: $resp"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Core update logic
# ---------------------------------------------------------------------------
do_update() {
    local force="${1:-no}"

    if [[ "$DDNS_ENABLED" != "yes" ]]; then
        log "DDNS is disabled (DDNS_ENABLED != yes)"
        return 0
    fi

    if [[ -z "$DDNS_PROVIDER" ]]; then
        log_err "DDNS_PROVIDER is not set"
        set_result "error: DDNS_PROVIDER not set"
        return 1
    fi

    local current_ip
    if ! current_ip="$(get_wan_ip)"; then
        set_result "error: could not determine WAN IP"
        return 1
    fi

    local last_ip=""
    [[ -f "$STATE_IP" ]] && last_ip="$(cat "$STATE_IP" 2>/dev/null || true)"

    if [[ "$force" != "yes" && "$current_ip" == "$last_ip" ]]; then
        log "IP unchanged ($current_ip) — no update needed"
        return 0
    fi

    log "Updating DDNS: provider=$DDNS_PROVIDER domain=${DDNS_DOMAIN:-<unset>} ip=$current_ip"

    local rc=0
    case "$DDNS_PROVIDER" in
        cloudflare) provider_cloudflare "$current_ip" || rc=$? ;;
        duckdns)    provider_duckdns    "$current_ip" || rc=$? ;;
        noip)       provider_noip       "$current_ip" || rc=$? ;;
        freedns)    provider_freedns    "$current_ip" || rc=$? ;;
        *)
            log_err "Unknown DDNS_PROVIDER: $DDNS_PROVIDER"
            set_result "error: unknown provider $DDNS_PROVIDER"
            return 1
            ;;
    esac

    mkdir -p "$RUNTIME_DIR"
    if [[ $rc -eq 0 ]]; then
        echo "$current_ip"         > "$STATE_IP"
        date +%s                   > "$STATE_UPDATE"
        echo "ok"                  > "$STATE_RESULT"
        log "DDNS update successful: $current_ip"
    else
        set_result "error: provider update failed (rc=$rc)"
        log_err "DDNS update failed for provider $DDNS_PROVIDER"
        return 1
    fi
}

cmd_status() {
    echo "=== DDNS Status ==="
    echo "  Enabled:       ${DDNS_ENABLED:-no}"
    echo "  Provider:      ${DDNS_PROVIDER:-(not set)}"
    echo "  Domain:        ${DDNS_DOMAIN:-(not set)}"

    local last_ip last_update last_result
    last_ip="$(cat "$STATE_IP" 2>/dev/null || echo "(none)")"
    last_result="$(cat "$STATE_RESULT" 2>/dev/null || echo "(no update yet)")"
    last_update=""
    if [[ -f "$STATE_UPDATE" ]]; then
        local epoch
        epoch="$(cat "$STATE_UPDATE" 2>/dev/null || true)"
        if [[ -n "$epoch" ]]; then
            last_update="$(date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                           || date -r "$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                           || echo "$epoch")"
        fi
    fi

    echo "  Last IP:       $last_ip"
    echo "  Last update:   ${last_update:-(never)}"
    echo "  Last result:   $last_result"

    # Show current WAN IP for comparison
    local current_ip
    current_ip="$(get_wan_ip 2>/dev/null || echo "(unavailable)")"
    echo "  Current WAN:   $current_ip"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
    update) do_update no  ;;
    force)  do_update yes ;;
    status) cmd_status    ;;
    *)
        echo "Usage: $0 {update|force|status}"
        exit 1
        ;;
esac
