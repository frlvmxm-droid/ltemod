import io
import ipaddress
import os
import re
import subprocess
import tarfile
import threading
from pathlib import Path
from urllib.parse import urlparse

from flask import (Flask, render_template, request, redirect, url_for,
                   session, flash, jsonify, send_file)

from auth import login_required, check_password, get_or_create_secret_key
from config import read_conf, write_conf, ALLOWED_KEYS
from status import (get_full_status, get_vpn_status, get_bypass_status,
                    get_dhcp_leases, get_static_leases, get_port_forwards,
                    get_traffic_data, get_ddns_status,
                    get_modem_detail, get_sms_list,
                    get_watchdog_state, get_desync_state, get_awg_profile)
from dpi import detect as dpi_detect, load_cached as dpi_load_cached, save_result as dpi_save, BLOCK_LABELS

SCRIPT_DIR = "/usr/local/bin/ltemod"
CONF_FILE = "/etc/ltemod/ltemod.conf"

app = Flask(__name__, template_folder="templates")
app.config.update(
    SECRET_KEY=get_or_create_secret_key(),
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    PERMANENT_SESSION_LIFETIME=86400 * 7,
    MAX_CONTENT_LENGTH=5 * 1024 * 1024,
)


def run_script(script_name: str, *args, timeout: int = 60):
    cmd = [f"{SCRIPT_DIR}/{script_name}"] + list(args)
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
            env={**os.environ, "CONFIG_FILE": CONF_FILE},
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return 1, "", f"Timed out after {timeout}s"
    except Exception as e:
        return 1, "", str(e)


# ── Auth ──────────────────────────────────────────────────────────────────────

@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        pw = request.form.get("password", "")
        if check_password(pw):
            session.permanent = True
            session["authenticated"] = True
            next_url = request.args.get("next") or ""
            parsed = urlparse(next_url)
            if not next_url or parsed.scheme or parsed.netloc:
                next_url = url_for("dashboard")
            return redirect(next_url)
        flash("Неверный пароль", "error")
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ── Pages ─────────────────────────────────────────────────────────────────────

@app.route("/")
@login_required
def index():
    return redirect(url_for("dashboard"))


@app.route("/dashboard")
@login_required
def dashboard():
    return render_template("dashboard.html")


@app.route("/lte-wifi", methods=["GET", "POST"])
@login_required
def lte_wifi():
    if request.method == "POST":
        lte_keys = {"APN", "APN_USER", "APN_PASS", "MODEM_PROTO",
                    "WWAN_IFACE", "USSD_BALANCE_CODE"}
        eth_keys = {"LAN_IFACE"}
        wifi_client_keys = {"WIFI_CLIENT_IFACE", "WIFI_CLIENT_SSID", "WIFI_CLIENT_PASSWORD"}
        wifi_ap_keys = {"WIFI_AP_SSID", "WIFI_AP_PASSWORD", "WIFI_AP_BAND",
                        "WIFI_AP_CHANNEL_2G", "WIFI_AP_CHANNEL_5G", "WIFI_AP_IP"}

        updates = {}
        for k in lte_keys | eth_keys | wifi_client_keys | wifi_ap_keys:
            if k in request.form:
                updates[k] = request.form[k]

        # Booleans from checkboxes
        updates["WIFI_AP_ENABLED"] = "yes" if request.form.get("WIFI_AP_ENABLED") else "no"

        # UPLINK_MODE from radio
        if "UPLINK_MODE" in request.form:
            updates["UPLINK_MODE"] = request.form["UPLINK_MODE"]
            # Auto-sync WIFI_CLIENT_ENABLED
            updates["WIFI_CLIENT_ENABLED"] = "yes" if updates["UPLINK_MODE"] == "wifi-client" else "no"

        try:
            write_conf(updates)
            flash("Настройки сохранены. Перезагрузи устройство для применения нового источника интернета.", "success")
        except Exception as e:
            flash(f"Ошибка сохранения: {e}", "error")

        if request.form.get("restart_wifi"):
            rc, _, err = run_script("setup-ap.sh", "restart", timeout=30)
            flash("WiFi AP перезапущен" if rc == 0 else f"Ошибка перезапуска AP: {err}",
                  "info" if rc == 0 else "error")

        if request.form.get("restart_uplink"):
            result = subprocess.run(
                ["systemctl", "restart", "lte-modem.service"],
                capture_output=True, text=True, timeout=90,
            )
            flash("Uplink перезапущен" if result.returncode == 0 else
                  f"Ошибка перезапуска uplink: {result.stderr}", "info" if result.returncode == 0 else "error")

        return redirect(url_for("lte_wifi"))

    conf = read_conf()
    from status import get_uplink_status
    uplink_st = get_uplink_status(conf)
    return render_template("lte_wifi.html", config=conf, uplink=uplink_st)


@app.route("/vpn", methods=["GET"])
@login_required
def vpn():
    conf = read_conf()
    vpn_st = get_vpn_status(conf)

    profiles = []
    profiles_dir = Path("/etc/ltemod/profiles")
    if profiles_dir.exists():
        for p in sorted(profiles_dir.iterdir()):
            if p.is_dir() and (p / "meta.conf").exists():
                meta: dict = {}
                for line in (p / "meta.conf").read_text().splitlines():
                    if "=" in line:
                        k, v = line.split("=", 1)
                        meta[k.strip()] = v.strip()
                profiles.append({"name": p.name, **meta})

    return render_template("vpn.html", config=conf, vpn=vpn_st, profiles=profiles)


@app.route("/bypass", methods=["GET", "POST"])
@login_required
def bypass():
    if request.method == "POST":
        updates = {
            "BYPASS_ENABLED": "yes" if request.form.get("BYPASS_ENABLED") else "no",
            "BYPASS_MODE": request.form.get("BYPASS_MODE", "selective"),
            "BYPASS_LIST_PRESET": request.form.get("BYPASS_LIST_PRESET", "none"),
        }
        try:
            write_conf(updates)
            flash("Настройки bypass сохранены", "success")
        except Exception as e:
            flash(f"Ошибка: {e}", "error")
        return redirect(url_for("bypass"))

    conf = read_conf()
    bypass_st = get_bypass_status(conf)
    return render_template("bypass.html", config=conf, bypass=bypass_st)


# ── JSON API ──────────────────────────────────────────────────────────────────

@app.route("/api/status")
@login_required
def api_status():
    return jsonify(get_full_status())


@app.route("/api/config", methods=["GET", "POST"])
@login_required
def api_config():
    if request.method == "POST":
        data = request.get_json(force=True) or {}
        try:
            write_conf({k: v for k, v in data.items() if k in ALLOWED_KEYS})
            return jsonify({"ok": True})
        except Exception as e:
            return jsonify({"ok": False, "error": str(e)}), 400
    return jsonify(read_conf())


@app.route("/api/vpn/toggle", methods=["POST"])
@login_required
def api_vpn_toggle():
    data = request.get_json(force=True) or {}
    proto = data.get("proto", "")
    action = data.get("action", "on")

    if proto == "off" or action == "off":
        rc, out, err = run_script("vpn-toggle.sh", "off", timeout=30)
    elif proto in ("wg", "amnezia", "vless") and action in ("on", "off"):
        rc, out, err = run_script("vpn-toggle.sh", proto, action, timeout=60)
    else:
        return jsonify({"ok": False, "error": "invalid proto/action"}), 400

    mode_file = Path("/run/ltemod/mode")
    mode = mode_file.read_text().strip() if mode_file.exists() else "direct"

    if rc != 0:
        return jsonify({"ok": False, "error": err or out, "mode": mode}), 500
    return jsonify({"ok": True, "mode": mode, "output": out})


@app.route("/vpn/upload", methods=["POST"])
@login_required
def vpn_upload():
    from werkzeug.utils import secure_filename

    proto = request.form.get("proto", "")
    f = request.files.get("vpnconfig")

    if not f or not f.filename:
        flash("Файл не выбран", "error")
        return redirect(url_for("vpn"))

    suffix = Path(secure_filename(f.filename)).suffix.lower()
    if suffix not in {".conf", ".json"}:
        flash("Только .conf и .json файлы разрешены", "error")
        return redirect(url_for("vpn"))

    tmp_path = f"/tmp/ltemod-vpn-upload{suffix}"
    try:
        f.save(tmp_path)
        os.chmod(tmp_path, 0o600)
    except OSError as e:
        flash(f"Ошибка сохранения файла: {e}", "error")
        return redirect(url_for("vpn"))

    script_map = {"wg": "setup-vpn.sh", "amnezia": "setup-amnezia.sh", "vless": "setup-vless.sh"}
    script = script_map.get(proto)
    if not script:
        os.unlink(tmp_path)
        flash("Неизвестный протокол VPN", "error")
        return redirect(url_for("vpn"))

    rc, out, err = run_script(script, tmp_path, timeout=30)
    try:
        os.unlink(tmp_path)
    except Exception:
        pass

    if rc != 0:
        flash(f"Ошибка установки конфига: {err or out}", "error")
    else:
        flash(f"VPN конфиг установлен ({proto.upper()}). Теперь включите VPN.", "success")
    return redirect(url_for("vpn"))


@app.route("/api/vpn/profiles")
@login_required
def api_vpn_profiles():
    profiles = []
    profiles_dir = Path("/etc/ltemod/profiles")
    if profiles_dir.exists():
        for p in sorted(profiles_dir.iterdir()):
            if p.is_dir() and (p / "meta.conf").exists():
                meta: dict = {}
                for line in (p / "meta.conf").read_text().splitlines():
                    if "=" in line:
                        k, v = line.split("=", 1)
                        meta[k.strip()] = v.strip()
                profiles.append({"name": p.name, **meta})
    return jsonify(profiles)


@app.route("/api/vpn/profile/use", methods=["POST"])
@login_required
def api_vpn_profile_use():
    data = request.get_json(force=True) or {}
    name = data.get("name", "")
    if not name or "/" in name or ".." in name:
        return jsonify({"ok": False, "error": "invalid profile name"}), 400
    rc, out, err = run_script("vpn-profile.sh", "use", name, timeout=60)
    if rc != 0:
        return jsonify({"ok": False, "error": err or out}), 500
    return jsonify({"ok": True, "output": out})


@app.route("/api/bypass/update-lists", methods=["POST"])
@login_required
def api_bypass_update_lists():
    def _update():
        try:
            subprocess.run(
                [f"{SCRIPT_DIR}/list-manager.sh", "update"],
                capture_output=True, timeout=300,
                env={**os.environ, "CONFIG_FILE": CONF_FILE},
            )
        except Exception:
            pass

    threading.Thread(target=_update, daemon=True).start()
    return jsonify({"ok": True, "message": "Обновление запущено в фоне (~1-2 мин)"})


@app.route("/api/bypass/status")
@login_required
def api_bypass_status():
    conf = read_conf()
    return jsonify(get_bypass_status(conf))


@app.route("/api/ap/restart", methods=["POST"])
@login_required
def api_ap_restart():
    rc, _, err = run_script("setup-ap.sh", "restart", timeout=30)
    return jsonify({"ok": rc == 0, "error": err if rc != 0 else None})


@app.route("/api/wifi/scan")
@login_required
def api_wifi_scan():
    conf = read_conf()
    ap_iface = conf.get("WIFI_AP_IFACE", "wlan0")
    wc_iface = conf.get("WIFI_CLIENT_IFACE", "wlan1")

    # Use wlan1 (STA iface) if up, otherwise scan on wlan0 (AP may allow passive scan)
    scan_iface = wc_iface if _iface_exists(wc_iface) else ap_iface

    networks = []
    try:
        # Force a fresh scan; parse terse output
        r = subprocess.run(
            ["nmcli", "--terse", "-f", "SSID,SIGNAL,SECURITY,CHAN,FREQ",
             "dev", "wifi", "list", "ifname", scan_iface, "--rescan", "yes"],
            capture_output=True, text=True, timeout=20,
        )
        seen: set = set()
        for line in r.stdout.splitlines():
            parts = line.split(":")
            if len(parts) < 4:
                continue
            ssid = parts[0].strip()
            if not ssid or ssid in seen:
                continue
            seen.add(ssid)
            try:
                signal = int(parts[1])
            except ValueError:
                signal = 0
            security = parts[2].strip() or "Open"
            chan = parts[3].strip()
            freq_raw = parts[4].strip() if len(parts) > 4 else ""
            freq_label = "2.4 GHz" if "2.4" in freq_raw or (freq_raw.isdigit() and int(freq_raw) < 3000) else "5 GHz"
            networks.append({
                "ssid": ssid,
                "signal": signal,
                "security": security,
                "channel": chan,
                "freq": freq_label,
            })

        # Sort by signal strength descending
        networks.sort(key=lambda x: x["signal"], reverse=True)

    except subprocess.TimeoutExpired:
        return jsonify({"ok": False, "error": "Сканирование прервано по таймауту (20с)"}), 504
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

    return jsonify({"ok": True, "networks": networks, "iface": scan_iface})


def _iface_exists(iface: str) -> bool:
    from pathlib import Path
    return Path(f"/sys/class/net/{iface}").exists()


@app.route("/api/modem/reconnect", methods=["POST"])
@login_required
def api_modem_reconnect():
    result = subprocess.run(
        ["systemctl", "restart", "lte-modem.service"],
        capture_output=True, text=True, timeout=60,
    )
    return jsonify({"ok": result.returncode == 0})


# ── Clients / DHCP ────────────────────────────────────────────────────────────

@app.route("/clients")
@login_required
def clients():
    leases = get_dhcp_leases()
    static = get_static_leases()
    return render_template("clients.html", leases=leases, static=static)


@app.route("/api/clients")
@login_required
def api_clients():
    return jsonify({"leases": get_dhcp_leases(), "static": get_static_leases()})


@app.route("/api/clients/static", methods=["POST", "DELETE"])
@login_required
def api_clients_static():
    data = request.get_json(force=True) or {}
    mac = data.get("mac", "").strip().lower()
    ip = data.get("ip", "").strip()
    hostname = data.get("hostname", "").strip()

    if not mac or not ip:
        return jsonify({"ok": False, "error": "mac and ip required"}), 400
    if not re.match(r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$', mac):
        return jsonify({"ok": False, "error": "invalid MAC (expect xx:xx:xx:xx:xx:xx)"}), 400
    try:
        ipaddress.IPv4Address(ip)
    except ValueError:
        return jsonify({"ok": False, "error": "invalid IP address"}), 400
    if hostname and not re.match(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$', hostname):
        return jsonify({"ok": False, "error": "invalid hostname"}), 400

    static_file = Path("/etc/dnsmasq.d/ltemod-static.conf")
    existing = static_file.read_text() if static_file.exists() else ""

    def _entry_mac(line: str) -> str:
        s = line.strip()
        if s.startswith("dhcp-host="):
            return s[len("dhcp-host="):].split(",")[0].lower()
        return ""

    lines = [l for l in existing.splitlines() if _entry_mac(l) != mac]

    if request.method == "POST":
        entry = f"dhcp-host={mac},{ip}"
        if hostname:
            entry += f",{hostname}"
        lines.append(entry)

    static_file.write_text("\n".join(lines) + ("\n" if lines else ""))
    subprocess.run(["systemctl", "reload-or-restart", "dnsmasq"],
                   capture_output=True, timeout=10)
    return jsonify({"ok": True})


# ── Firewall / Port Forwarding ─────────────────────────────────────────────────

@app.route("/firewall")
@login_required
def firewall():
    return render_template("firewall.html", rules=get_port_forwards())


@app.route("/api/portfwd", methods=["GET"])
@login_required
def api_portfwd_list():
    return jsonify(get_port_forwards())


@app.route("/api/portfwd", methods=["POST"])
@login_required
def api_portfwd_add():
    data = request.get_json(force=True) or {}
    name = re.sub(r"[^a-zA-Z0-9_-]", "_", data.get("name", "").strip())
    proto = data.get("proto", "tcp").lower()
    ext_port = str(data.get("ext_port", "")).strip()
    int_ip = data.get("int_ip", "").strip()
    int_port = str(data.get("int_port", "")).strip()

    if not all([name, proto, ext_port, int_ip, int_port]):
        return jsonify({"ok": False, "error": "all fields required"}), 400
    if proto not in ("tcp", "udp", "both"):
        return jsonify({"ok": False, "error": "proto must be tcp/udp/both"}), 400
    for p in (ext_port, int_port):
        if not p.isdigit() or not (1 <= int(p) <= 65535):
            return jsonify({"ok": False, "error": f"invalid port: {p}"}), 400
    try:
        ipaddress.IPv4Address(int_ip)
    except ValueError:
        return jsonify({"ok": False, "error": "invalid internal IP"}), 400

    pf_file = Path("/etc/ltemod/port-forward.conf")
    existing = pf_file.read_text() if pf_file.exists() else ""
    lines = [l for l in existing.splitlines() if l.strip() and not l.startswith(f"{name}:")]
    lines.append(f"{name}:{proto}:{ext_port}:{int_ip}:{int_port}")
    pf_file.write_text("\n".join(lines) + "\n")

    run_script("setup-portfwd.sh", "apply", timeout=15)
    return jsonify({"ok": True})


@app.route("/api/portfwd/<name>", methods=["DELETE"])
@login_required
def api_portfwd_del(name):
    name = re.sub(r"[^a-zA-Z0-9_-]", "_", name)
    pf_file = Path("/etc/ltemod/port-forward.conf")
    if pf_file.exists():
        lines = [l for l in pf_file.read_text().splitlines()
                 if l.strip() and not l.startswith(f"{name}:")]
        pf_file.write_text("\n".join(lines) + ("\n" if lines else ""))
    run_script("setup-portfwd.sh", "apply", timeout=15)
    return jsonify({"ok": True})


# ── Traffic ───────────────────────────────────────────────────────────────────

@app.route("/traffic")
@login_required
def traffic():
    conf = read_conf()
    return render_template("traffic.html", config=conf)


@app.route("/api/traffic")
@login_required
def api_traffic():
    conf = read_conf()
    return jsonify(get_traffic_data(conf.get("WWAN_IFACE", "wwan0")))


# ── Settings (DNS, DDNS, Failover, Backup) ────────────────────────────────────

@app.route("/settings", methods=["GET", "POST"])
@login_required
def settings():
    if request.method == "POST":
        action = request.form.get("action", "save")

        if action == "save":
            updates = {}
            for k in ("DNS_MODE", "DNS_SERVER", "DDNS_PROVIDER",
                      "DDNS_DOMAIN", "DDNS_TOKEN", "DDNS_ZONE_ID", "DDNS_USERNAME",
                      "DESYNC_MODE"):
                if k in request.form:
                    updates[k] = request.form[k]
            updates["DDNS_ENABLED"] = "yes" if request.form.get("DDNS_ENABLED") else "no"
            updates["FAILOVER_ENABLED"] = "yes" if request.form.get("FAILOVER_ENABLED") else "no"
            updates["DESYNC_ENABLED"] = "yes" if request.form.get("DESYNC_ENABLED") else "no"

            # Validate desync fields to prevent shell injection via config source
            desync_err = None
            if "DESYNC_PORTS" in request.form:
                ports_val = request.form["DESYNC_PORTS"].strip()
                if ports_val and not re.match(r'^[0-9]+(,[0-9]+)*$', ports_val):
                    desync_err = "DESYNC_PORTS: только цифры, разделённые запятыми"
                else:
                    updates["DESYNC_PORTS"] = ports_val
            if "DESYNC_MSS" in request.form:
                mss_val = request.form["DESYNC_MSS"].strip()
                if mss_val:
                    try:
                        mss_int = int(mss_val)
                        if not (40 <= mss_int <= 1460):
                            desync_err = "DESYNC_MSS: должно быть от 40 до 1460"
                        else:
                            updates["DESYNC_MSS"] = str(mss_int)
                    except ValueError:
                        desync_err = "DESYNC_MSS: должно быть целым числом"
                else:
                    updates["DESYNC_MSS"] = ""
            if "DESYNC_TTL" in request.form:
                ttl_val = request.form["DESYNC_TTL"].strip()
                if ttl_val:
                    try:
                        ttl_int = int(ttl_val)
                        if not (1 <= ttl_int <= 64):
                            desync_err = "DESYNC_TTL: должно быть от 1 до 64"
                        else:
                            updates["DESYNC_TTL"] = str(ttl_int)
                    except ValueError:
                        desync_err = "DESYNC_TTL: должно быть целым числом"
                else:
                    updates["DESYNC_TTL"] = ""

            if desync_err:
                flash(desync_err, "error")
            else:
                try:
                    write_conf(updates)
                    flash("Настройки сохранены", "success")
                except Exception as e:
                    flash(f"Ошибка: {e}", "error")
            if "DNS_MODE" in updates or "DNS_SERVER" in updates:
                rc, _, err = run_script("setup-dns.sh", "apply", timeout=60)
                if rc != 0:
                    flash(f"DNS: {err or 'ошибка применения'}", "error")
                else:
                    flash("DNS режим применён", "info")

        elif action == "ddns_update":
            threading.Thread(
                target=lambda: run_script("setup-ddns.sh", "force", timeout=30),
                daemon=True,
            ).start()
            flash("DDNS обновление запущено", "info")

        return redirect(url_for("settings"))

    conf = read_conf()
    ddns_st = get_ddns_status()
    return render_template("settings.html", config=conf, ddns=ddns_st)


_SENSITIVE_FILES = {"web-auth", "web-secret"}


@app.route("/api/backup")
@login_required
def api_backup():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        conf_dir = Path("/etc/ltemod")
        if conf_dir.exists():
            for f in sorted(conf_dir.rglob("*")):
                if (f.is_file()
                        and not f.name.endswith((".pyc", ".new"))
                        and f.name not in _SENSITIVE_FILES):
                    tar.add(str(f), arcname=str(f.relative_to("/etc")))
    buf.seek(0)
    return send_file(buf, mimetype="application/gzip",
                     as_attachment=True, download_name="ltemod-backup.tar.gz")


@app.route("/api/restore", methods=["POST"])
@login_required
def api_restore():
    f = request.files.get("backup")
    if not f:
        return jsonify({"ok": False, "error": "no file"}), 400
    try:
        buf = io.BytesIO(f.read())
        with tarfile.open(fileobj=buf, mode="r:gz") as tar:
            for member in tar.getmembers():
                safe_name = member.name.lstrip("/")
                if not safe_name.startswith("ltemod/") or ".." in safe_name:
                    continue
                if Path(safe_name).name in _SENSITIVE_FILES:
                    continue
                member.name = safe_name
                tar.extract(member, "/etc", filter="data")
        return jsonify({"ok": True, "message": "Конфиг восстановлен. Перезагрузка рекомендована."})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.route("/api/ddns/status")
@login_required
def api_ddns_status():
    return jsonify(get_ddns_status())


# ── DPI Detection ─────────────────────────────────────────────────────────────

_dpi_running = False
_dpi_lock = threading.Lock()


@app.route("/dpi")
@login_required
def dpi_page():
    cached = dpi_load_cached()
    return render_template("dpi.html", result=cached, labels=BLOCK_LABELS)


@app.route("/api/dpi/detect", methods=["POST"])
@login_required
def api_dpi_detect():
    global _dpi_running
    with _dpi_lock:
        if _dpi_running:
            return jsonify({"ok": False, "error": "Проверка уже выполняется"}), 409
        _dpi_running = True

    def _run():
        global _dpi_running
        try:
            r = dpi_detect()
            dpi_save(r)
        finally:
            with _dpi_lock:
                _dpi_running = False

    threading.Thread(target=_run, daemon=True).start()
    return jsonify({"ok": True, "message": "Проверка DPI запущена (~10-30 сек)"})


@app.route("/api/dpi/status")
@login_required
def api_dpi_status():
    cached = dpi_load_cached()
    running = _dpi_running
    if cached is None:
        return jsonify({"running": running, "result": None})
    return jsonify({"running": running, "result": cached})


# ── AWG Obfuscation Profiles ──────────────────────────────────────────────────

@app.route("/api/awg/profile", methods=["POST"])
@login_required
def api_awg_profile():
    data = request.get_json(force=True) or {}
    profile = data.get("profile", "").strip()
    if profile not in ("mild", "moderate", "aggressive"):
        return jsonify({"ok": False, "error": "profile must be mild/moderate/aggressive"}), 400

    rc, out, err = run_script("setup-awg-profiles.sh", "apply", profile, timeout=30)
    if rc != 0:
        return jsonify({"ok": False, "error": err or out}), 500

    try:
        write_conf({"AWG_PROFILE": profile})
    except Exception as e:
        app.logger.warning("Failed to persist AWG_PROFILE: %s", e)

    return jsonify({"ok": True, "profile": profile, "output": out})


# ── TCP Desync ────────────────────────────────────────────────────────────────

@app.route("/api/desync/apply", methods=["POST"])
@login_required
def api_desync_apply():
    conf = read_conf()
    enabled = conf.get("DESYNC_ENABLED", "no") == "yes"
    if not enabled:
        run_script("setup-desync.sh", "stop", timeout=15)
        return jsonify({"ok": True, "message": "Desync выключен"})
    rc, out, err = run_script("setup-desync.sh", "start", timeout=30)
    if rc != 0:
        return jsonify({"ok": False, "error": err or out}), 500
    return jsonify({"ok": True, "output": out})


@app.route("/api/desync/status")
@login_required
def api_desync_status():
    return jsonify({"mode": get_desync_state()})


# ── Modem page ────────────────────────────────────────────────────────────────

@app.route("/modem")
@login_required
def modem_page():
    conf = read_conf()
    return render_template("modem.html", config=conf, modem=get_modem_detail())


@app.route("/api/modem/detail")
@login_required
def api_modem_detail():
    return jsonify(get_modem_detail())


@app.route("/api/modem/ussd", methods=["POST"])
@login_required
def api_modem_ussd():
    data = request.get_json(force=True) or {}
    code = data.get("code", "").strip()
    if not re.match(r'^[\*#0-9]+[#]?$', code):
        return jsonify({"ok": False, "error": "invalid USSD code"}), 400
    rc, out, err = run_script("sms.sh", "ussd", code, timeout=30)
    return jsonify({"ok": rc == 0, "output": (out + err).strip()})


@app.route("/api/modem/sms", methods=["GET"])
@login_required
def api_modem_sms_list():
    return jsonify(get_sms_list())


@app.route("/api/modem/sms/send", methods=["POST"])
@login_required
def api_modem_sms_send():
    data = request.get_json(force=True) or {}
    number = data.get("number", "").strip()
    text = data.get("text", "").strip()[:160]
    if not number or not text:
        return jsonify({"ok": False, "error": "number and text required"}), 400
    if not re.match(r'^\+?[0-9]{7,15}$', number):
        return jsonify({"ok": False, "error": "invalid phone number"}), 400
    rc, out, err = run_script("sms.sh", "send", number, text, timeout=30)
    return jsonify({"ok": rc == 0, "output": (out + err).strip()})


# ── Diagnostics page ──────────────────────────────────────────────────────────

@app.route("/diagnostics")
@login_required
def diagnostics():
    return render_template("diagnostics.html",
                           watchdog=get_watchdog_state(),
                           desync=get_desync_state(),
                           awg_profile=get_awg_profile())


@app.route("/api/diagnostics/doctor", methods=["POST"])
@login_required
def api_diagnostics_doctor():
    rc, out, err = run_script("ltemod-doctor.sh", timeout=30)
    return jsonify({"ok": rc == 0, "output": (out + err).strip()})


@app.route("/api/diagnostics/hardware", methods=["POST"])
@login_required
def api_diagnostics_hardware():
    rc, out, err = run_script("detect-hardware.sh", timeout=15)
    return jsonify({"ok": rc == 0, "output": (out + err).strip()})


@app.route("/api/diagnostics/sim", methods=["POST"])
@login_required
def api_diagnostics_sim():
    rc, out, err = run_script("detect-sim.sh", timeout=20)
    return jsonify({"ok": rc == 0, "output": (out + err).strip()})


@app.route("/api/diagnostics/journal")
@login_required
def api_diagnostics_journal():
    try:
        r = subprocess.run(
            ["journalctl", "-t", "ltemod", "-t", "ltemod-watchdog",
             "-t", "ltemod-ddns", "-t", "ltemod-desync",
             "-n", "80", "--no-pager", "--output=short-iso"],
            capture_output=True, text=True, timeout=5,
        )
        return jsonify({"ok": True, "lines": r.stdout.strip().splitlines()[-80:]})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e), "lines": []})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False, threaded=True)
