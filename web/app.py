import os
import subprocess
import threading
from pathlib import Path

from flask import (Flask, render_template, request, redirect, url_for,
                   session, flash, jsonify, abort)

from auth import login_required, check_password, get_or_create_secret_key
from config import read_conf, write_conf, ALLOWED_KEYS
from status import get_full_status, get_vpn_status, get_bypass_status

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
            next_url = request.args.get("next") or url_for("dashboard")
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


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False, threaded=True)
