import re
import shlex
from pathlib import Path

CONF_PATH = Path("/etc/ltemod/ltemod.conf")

ALLOWED_KEYS = {
    # Uplink
    "UPLINK_MODE", "LAN_IFACE", "UPLINK_PRIORITY",
    # LTE
    "APN", "APN_USER", "APN_PASS", "MODEM_PROTO", "WWAN_IFACE",
    "USSD_BALANCE_CODE",
    # WiFi client (upstream)
    "WIFI_CLIENT_ENABLED", "WIFI_CLIENT_IFACE",
    "WIFI_CLIENT_SSID", "WIFI_CLIENT_PASSWORD",
    # WiFi AP
    "WIFI_AP_ENABLED", "WIFI_AP_SSID", "WIFI_AP_PASSWORD",
    "WIFI_AP_BAND", "WIFI_AP_CHANNEL_2G", "WIFI_AP_CHANNEL_5G", "WIFI_AP_IP",
    # VPN
    "VPN_PROTO", "VPN_KILLSWITCH", "VPN_DNS_REDIRECT",
    # Bypass
    "BYPASS_ENABLED", "BYPASS_MODE", "BYPASS_LIST_PRESET",
    # DNS
    "DNS_MODE", "DNS_SERVER",
    # DDNS
    "DDNS_ENABLED", "DDNS_PROVIDER", "DDNS_DOMAIN", "DDNS_TOKEN",
    "DDNS_ZONE_ID", "DDNS_USERNAME",
    # WAN Failover
    "FAILOVER_ENABLED",
    # TCP Desync (DPI bypass)
    "DESYNC_ENABLED", "DESYNC_MODE", "DESYNC_PORTS", "DESYNC_MSS", "DESYNC_TTL",
    # AmneziaWG obfuscation profile
    "AWG_PROFILE",
}

# Matches the KEY= prefix of a config line (value may be quoted any way).
_RE_LINE_KEY = re.compile(r'^([A-Z_][A-Z0-9_]*)\s*=')


def _sq(val: str) -> str:
    """Return val single-quoted for safe shell sourcing.

    Single-quoting is the only quoting mode that prevents ALL shell expansion
    ($, ``, \\, etc.).  Single-quotes within the value are escaped as '\\''
    (close-quote, literal-quote, reopen-quote).
    """
    return "'" + str(val).replace("'", "'\\''") + "'"


def read_conf() -> dict:
    result = {}
    if not CONF_PATH.exists():
        return result
    for line in CONF_PATH.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        m = _RE_LINE_KEY.match(stripped)
        if not m:
            continue
        key = m.group(1)
        rest = stripped[m.end():]          # everything after KEY=
        try:
            vals = shlex.split(rest)
            result[key] = vals[0] if vals else ''
        except ValueError:
            # Malformed quoting — best-effort strip
            result[key] = rest.strip().strip("'\"")
    return result


def write_conf(updates: dict) -> None:
    bad = set(updates) - ALLOWED_KEYS
    if bad:
        raise ValueError(f"Forbidden config keys: {bad}")

    text = CONF_PATH.read_text()
    lines = text.splitlines(keepends=True)

    updated: set = set()
    new_lines = []
    for line in lines:
        m = _RE_LINE_KEY.match(line.strip())
        if m and m.group(1) in updates:
            key = m.group(1)
            new_lines.append(f'{key}={_sq(updates[key])}\n')
            updated.add(key)
        else:
            new_lines.append(line)

    # Append keys that weren't present in the file at all
    missing = set(updates) - updated
    if missing:
        if new_lines and not new_lines[-1].endswith("\n"):
            new_lines.append("\n")
        for key in sorted(missing):
            new_lines.append(f'{key}={_sq(updates[key])}\n')

    CONF_PATH.write_text("".join(new_lines))
