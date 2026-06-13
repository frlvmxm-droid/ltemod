#!/bin/bash
# =============================================================================
# vpn-profile.sh — менеджер именованных VPN-профилей
#
# Хранит несколько VPN-конфигов (wg / amnezia / vless) и переключается между
# ними одной командой.
#
# Использование:
#   vpn-profile add <name> <file> [wg|amnezia|vless]  — добавить профиль
#   vpn-profile list                                  — список профилей
#   vpn-profile use <name>                            — активировать + поднять VPN
#   vpn-profile current                               — активный профиль
#   vpn-profile show <name>                           — показать конфиг
#   vpn-profile rm <name>                             — удалить профиль
#
# Хранилище: $PROFILE_DIR/<name>/{config,proto}
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ltemod/ltemod.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

PROFILE_DIR="${PROFILE_DIR:-/etc/ltemod/profiles}"
ACTIVE_FILE="${ACTIVE_FILE:-/etc/ltemod/active_profile}"
LOG_TAG="${LOG_TAG:-ltemod}"

# Пути установки скриптов (для вызова setup-* и vpn-toggle)
BIN_DIR="/usr/local/bin"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { logger -t "${LOG_TAG}-profile" "$*"; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
fail()    { echo -e "  ${RED}✗${NC} $*"; }
info()    { echo -e "  ${YELLOW}→${NC} $*"; }
err()     { echo -e "${RED}ERROR:${NC} $*" >&2; }

need_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This command requires root: sudo $0 $*"
        exit 1
    fi
}

# Определить протокол по содержимому файла
detect_proto() {
    local f="$1"
    # VLESS — валидный JSON с inbounds/outbounds
    if command -v jq &>/dev/null && jq -e . "$f" &>/dev/null; then
        echo "vless"; return 0
    fi
    if grep -qE '"(inbounds|outbounds)"' "$f" 2>/dev/null; then
        echo "vless"; return 0
    fi
    # AmneziaWG — WireGuard-формат с параметрами обфускации (Jc/Jmin/H1...)
    if grep -qE '^\s*(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)\s*=' "$f" 2>/dev/null; then
        echo "amnezia"; return 0
    fi
    # WireGuard — секция [Interface]
    if grep -qE '^\s*\[Interface\]' "$f" 2>/dev/null; then
        echo "wg"; return 0
    fi
    return 1
}

# Команда активации/валидации для протокола
setup_cmd_for() {
    case "$1" in
        wg)      echo "$BIN_DIR/setup-vpn" ;;
        amnezia) echo "$BIN_DIR/setup-amnezia" ;;
        vless)   echo "$BIN_DIR/setup-vless" ;;
    esac
}

profile_proto() {
    local name="$1"
    [[ -f "$PROFILE_DIR/$name/proto" ]] && cat "$PROFILE_DIR/$name/proto" || echo "?"
}

# ---------------------------------------------------------------------------
cmd_add() {
    need_root "$@"
    local name="${1:-}" file="${2:-}" proto="${3:-}"
    if [[ -z "$name" || -z "$file" ]]; then
        err "Usage: $0 add <name> <file> [wg|amnezia|vless]"; exit 1
    fi
    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "Profile name must be [A-Za-z0-9_-]"; exit 1
    fi
    if [[ ! -f "$file" ]]; then
        err "File not found: $file"; exit 1
    fi

    if [[ -z "$proto" ]]; then
        proto=$(detect_proto "$file") || {
            err "Cannot detect protocol. Specify explicitly: $0 add $name $file <wg|amnezia|vless>"
            exit 1
        }
        info "Detected protocol: $proto"
    fi
    case "$proto" in wg|amnezia|vless) ;; *) err "Invalid protocol: $proto"; exit 1 ;; esac

    mkdir -p "$PROFILE_DIR/$name"
    chmod 700 "$PROFILE_DIR" "$PROFILE_DIR/$name"
    cp "$file" "$PROFILE_DIR/$name/config"
    chmod 600 "$PROFILE_DIR/$name/config"
    echo "$proto" > "$PROFILE_DIR/$name/proto"

    log "Profile added: $name ($proto)"
    ok "Profile '$name' added (protocol: $proto)"
    info "Activate with: sudo $0 use $name"
}

cmd_list() {
    local active=""
    [[ -f "$ACTIVE_FILE" ]] && active=$(cat "$ACTIVE_FILE")
    echo -e "${CYAN}=== VPN profiles ===${NC}"
    if [[ ! -d "$PROFILE_DIR" ]] || [[ -z "$(ls -A "$PROFILE_DIR" 2>/dev/null)" ]]; then
        info "No profiles yet. Add one: sudo $0 add <name> <file>"
        return 0
    fi
    for d in "$PROFILE_DIR"/*/; do
        [[ -d "$d" ]] || continue
        local n; n=$(basename "$d")
        local p; p=$(profile_proto "$n")
        if [[ "$n" == "$active" ]]; then
            ok "$n  [$p]  ${GREEN}(active)${NC}"
        else
            echo -e "    $n  [$p]"
        fi
    done
}

cmd_use() {
    need_root "$@"
    local name="${1:-}"
    [[ -z "$name" ]] && { err "Usage: $0 use <name>"; exit 1; }
    local pdir="$PROFILE_DIR/$name"
    if [[ ! -d "$pdir" ]]; then
        err "Profile not found: $name (see: $0 list)"; exit 1
    fi
    local proto; proto=$(profile_proto "$name")
    local setup; setup=$(setup_cmd_for "$proto")
    if [[ ! -x "$setup" && ! -f "$setup" ]]; then
        err "Setup tool for '$proto' not found ($setup). Run install.sh"; exit 1
    fi

    info "Activating profile '$name' ($proto)..."
    # Установить конфиг профиля через штатный setup-* (он валидирует и кладёт
    # в каноничный путь WG_CONFIG/AMNEZIA_CONFIG/VLESS_CONFIG)
    if ! bash "$setup" "$pdir/config"; then
        err "Validation/install failed for profile '$name'"; exit 1
    fi

    # Поднять VPN выбранного протокола
    if ! bash "$BIN_DIR/vpn-toggle" "$proto" on; then
        err "Failed to enable VPN ($proto)"; exit 1
    fi

    echo "$name" > "$ACTIVE_FILE"
    log "Profile activated: $name ($proto)"
    ok "Profile '$name' is now active ($proto)"
}

cmd_current() {
    if [[ -f "$ACTIVE_FILE" ]]; then
        local n; n=$(cat "$ACTIVE_FILE")
        ok "Active profile: $n [$(profile_proto "$n")]"
    else
        info "No active profile"
    fi
}

cmd_show() {
    local name="${1:-}"
    [[ -z "$name" ]] && { err "Usage: $0 show <name>"; exit 1; }
    local cfg="$PROFILE_DIR/$name/config"
    [[ -f "$cfg" ]] || { err "Profile not found: $name"; exit 1; }
    echo -e "${CYAN}=== Profile: $name [$(profile_proto "$name")] ===${NC}"
    cat "$cfg"
}

cmd_rm() {
    need_root "$@"
    local name="${1:-}"
    [[ -z "$name" ]] && { err "Usage: $0 rm <name>"; exit 1; }
    [[ -d "$PROFILE_DIR/$name" ]] || { err "Profile not found: $name"; exit 1; }
    rm -rf "${PROFILE_DIR:?}/$name"
    [[ -f "$ACTIVE_FILE" && "$(cat "$ACTIVE_FILE")" == "$name" ]] && rm -f "$ACTIVE_FILE"
    log "Profile removed: $name"
    ok "Profile '$name' removed"
}

# ---------------------------------------------------------------------------
case "${1:-list}" in
    add)     shift; cmd_add "$@" ;;
    list|ls) cmd_list ;;
    use)     shift; cmd_use "$@" ;;
    current) cmd_current ;;
    show)    shift; cmd_show "$@" ;;
    rm|del)  shift; cmd_rm "$@" ;;
    *)
        echo "Usage: $0 {add|list|use|current|show|rm}"
        echo "  add <name> <file> [proto]  — добавить профиль (proto автодетект)"
        echo "  list                       — список профилей"
        echo "  use <name>                 — активировать профиль + поднять VPN"
        echo "  current                    — активный профиль"
        echo "  show <name>                — показать конфиг профиля"
        echo "  rm <name>                  — удалить профиль"
        exit 1
        ;;
esac
