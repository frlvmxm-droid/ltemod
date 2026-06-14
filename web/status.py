import re
import subprocess
import time
from pathlib import Path


def _run(cmd, timeout=5):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout, r.returncode
    except Exception:
        return "", 1


def get_lte_status(wwan_iface: str) -> dict:
    result = {
        "iface": wwan_iface, "up": False, "ip": None,
        "operator": None, "signal_pct": None,
        "rx_bytes": 0, "tx_bytes": 0,
    }

    out, rc = _run(["ip", "addr", "show", wwan_iface])
    if rc == 0:
        result["up"] = True
        m = re.search(r"inet (\S+)", out)
        if m:
            result["ip"] = m.group(1)

    base = Path(f"/sys/class/net/{wwan_iface}/statistics")
    if base.exists():
        try:
            result["rx_bytes"] = int((base / "rx_bytes").read_text().strip())
            result["tx_bytes"] = int((base / "tx_bytes").read_text().strip())
        except Exception:
            pass

    mm_out, mm_rc = _run(["mmcli", "-L"], timeout=3)
    m = re.search(r"/Modems/(\d+)", mm_out)
    if m:
        idx = m.group(1)
        detail, _ = _run(["mmcli", "-m", idx, "-K"], timeout=5)
        for line in detail.splitlines():
            if "operator-name" in line and not result["operator"]:
                result["operator"] = line.split(":", 1)[-1].strip() or None
            elif "signal-quality.value" in line:
                try:
                    result["signal_pct"] = int(line.split(":", 1)[-1].strip())
                except ValueError:
                    pass

    return result


def get_vpn_status(cfg: dict) -> dict:
    mode_file = Path("/run/ltemod/mode")
    active_mode = mode_file.read_text().strip() if mode_file.exists() else "direct"

    wg_iface = cfg.get("VPN_IFACE", "wg0")
    awg_iface = cfg.get("AMNEZIA_IFACE", "awg0")
    tun_iface = cfg.get("VLESS_TUN_IFACE", "tun0")

    result = {
        "proto": cfg.get("VPN_PROTO", "none"),
        "active_mode": active_mode,
        "killswitch": cfg.get("VPN_KILLSWITCH", "no") == "yes",
        "dns_redirect": cfg.get("VPN_DNS_REDIRECT", "no") == "yes",
        "wg": {"up": False, "iface": wg_iface, "ip": None, "handshake_age_sec": None, "healthy": False},
        "amnezia": {"up": False, "iface": awg_iface},
        "vless": {"running": False, "tun_up": False, "iface": tun_iface},
    }

    # WireGuard
    _, rc = _run(["ip", "link", "show", wg_iface])
    if rc == 0:
        result["wg"]["up"] = True
        addr_out, _ = _run(["ip", "addr", "show", wg_iface])
        m = re.search(r"inet (\S+)", addr_out)
        if m:
            result["wg"]["ip"] = m.group(1)
        hs_out, hs_rc = _run(["wg", "show", wg_iface, "latest-handshakes"])
        if hs_rc == 0:
            for hs_line in hs_out.strip().splitlines():
                parts = hs_line.split()
                if len(parts) >= 2 and parts[1].isdigit() and parts[1] != "0":
                    age = int(time.time()) - int(parts[1])
                    result["wg"]["handshake_age_sec"] = age
                    result["wg"]["healthy"] = age < 180

    # AmneziaWG
    _, rc = _run(["ip", "link", "show", awg_iface])
    if rc == 0:
        result["amnezia"]["up"] = True

    # VLESS / sing-box
    out, _ = _run(["systemctl", "is-active", "sing-box"])
    result["vless"]["running"] = out.strip() == "active"
    _, rc = _run(["ip", "link", "show", tun_iface])
    if rc == 0:
        result["vless"]["tun_up"] = True

    return result


def get_wifi_status(cfg: dict) -> dict:
    result = {
        "enabled": cfg.get("WIFI_AP_ENABLED", "no") == "yes",
        "running": False,
        "ssid": cfg.get("WIFI_AP_SSID", ""),
        "band": cfg.get("WIFI_AP_BAND", "2g"),
        "ip": cfg.get("WIFI_AP_IP", "192.168.10.1"),
        "client_count": 0,
    }

    out, _ = _run(["systemctl", "is-active", "wifi-ap"])
    result["running"] = out.strip() == "active"

    wlan = cfg.get("WIFI_AP_IFACE", "wlan0")
    out, rc = _run(["iw", "dev", wlan, "station", "dump"])
    if rc == 0:
        result["client_count"] = out.count("Station ")

    return result


def get_bypass_status(cfg: dict) -> dict:
    result = {
        "enabled": cfg.get("BYPASS_ENABLED", "no") == "yes",
        "active": False,
        "mode": cfg.get("BYPASS_MODE", "selective"),
        "preset": cfg.get("BYPASS_LIST_PRESET", "none"),
        "ipset_ip_count": 0,
        "ipset_net_count": 0,
    }

    out, rc = _run(["ipset", "list", "ltemod_bypass_ip", "-t"])
    if rc == 0:
        m = re.search(r"Number of entries: (\d+)", out)
        if m:
            result["ipset_ip_count"] = int(m.group(1))
            result["active"] = True

    out, rc = _run(["ipset", "list", "ltemod_bypass_net", "-t"])
    if rc == 0:
        m = re.search(r"Number of entries: (\d+)", out)
        if m:
            result["ipset_net_count"] = int(m.group(1))

    return result


def get_service_states() -> dict:
    services = ["lte-modem", "wifi-ap", "lte-watchdog.timer", "sing-box", "ltemod-web"]
    result = {}
    for svc in services:
        out, _ = _run(["systemctl", "is-active", svc])
        result[svc] = out.strip()
    return result


def get_uplink_status(cfg: dict) -> dict:
    uplink_mode = cfg.get("UPLINK_MODE", "lte")
    lan_iface = cfg.get("LAN_IFACE", "end0")
    wc_iface = cfg.get("WIFI_CLIENT_IFACE", "wlan1")

    # Read runtime uplink info written by setup-uplink.sh / setup-routing.sh
    rt_mode_file = Path("/run/ltemod/uplink_mode")
    rt_iface_file = Path("/run/ltemod/uplink_iface")
    active_mode = rt_mode_file.read_text().strip() if rt_mode_file.exists() else uplink_mode
    active_iface = rt_iface_file.read_text().strip() if rt_iface_file.exists() else ""

    result = {
        "config_mode": uplink_mode,
        "active_mode": active_mode,
        "active_iface": active_iface,
        "eth": {"iface": lan_iface, "up": False, "ip": None},
        "wifi_client": {"iface": wc_iface, "up": False, "ip": None, "ssid": cfg.get("WIFI_CLIENT_SSID", "")},
    }

    # Ethernet status
    _, rc = _run(["ip", "link", "show", lan_iface])
    if rc == 0:
        addr_out, _ = _run(["ip", "addr", "show", lan_iface])
        m = re.search(r"inet (\S+)", addr_out)
        if m:
            result["eth"]["up"] = True
            result["eth"]["ip"] = m.group(1)

    # WiFi client status
    _, rc = _run(["ip", "link", "show", wc_iface])
    if rc == 0:
        addr_out, _ = _run(["ip", "addr", "show", wc_iface])
        m = re.search(r"inet (\S+)", addr_out)
        if m:
            result["wifi_client"]["up"] = True
            result["wifi_client"]["ip"] = m.group(1)
        # SSID
        link_out, _ = _run(["iw", "dev", wc_iface, "link"])
        m = re.search(r"SSID: (.+)", link_out)
        if m:
            result["wifi_client"]["ssid"] = m.group(1).strip()

    return result


def get_full_status(cfg: dict | None = None) -> dict:
    if cfg is None:
        from config import read_conf
        cfg = read_conf()

    out, _ = _run(["sysctl", "-n", "net.ipv4.ip_forward"])
    ip_forward = out.strip() == "1"

    _, ping_rc = _run(["ping", "-c", "1", "-W", "3", "8.8.8.8"], timeout=6)

    return {
        "timestamp": int(time.time()),
        "uplink": get_uplink_status(cfg),
        "lte": get_lte_status(cfg.get("WWAN_IFACE", "wwan0")),
        "vpn": get_vpn_status(cfg),
        "wifi_ap": get_wifi_status(cfg),
        "bypass": get_bypass_status(cfg),
        "system": {
            "internet_ok": ping_rc == 0,
            "ip_forward": ip_forward,
            "services": get_service_states(),
        },
    }
