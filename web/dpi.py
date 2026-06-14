"""
DPI detection module for ltemod.
Ported from DarkRoute daemon/internal/dpi/detector.go.

Runs a differential probe sequence to classify how traffic is being blocked:
  BlockDNS       — DNS poisoning / NXDOMAIN injection
  BlockTCP       — Hard IP/port block, RST injection
  BlockHTTP      — HTTP DPI, ISP stub page (РКН block page)
  BlockTLS       — TLS fingerprint block, SNI filtering, TSPU throttle
  BlockProtocol  — VPN protocol signature detected (WG/AWG handshake)
  BlockNone      — No DPI detected
"""
import json
import socket
import ssl
import time
import urllib.request
import urllib.error
from pathlib import Path
from typing import Optional

# Russian ISP block page markers (РКН/ТСПУ stub pages)
STUB_MARKERS = [
    "доступ ограничен",
    "доступ к запрашиваемому ресурсу",
    "решению роскомнадзора",
    "решением суда",
    "заблокирован",
    "blocked by roskomnadzor",
    "blocked by rkn",
    "rkn.gov.ru",
    "единый реестр",
    "запрещен",
    "ecofilter",
    "эко-фильтр",
]

# Default probe targets
DEFAULT_TARGETS = [
    ("1.1.1.1", 443),
    ("cloudflare.com", 443),
    ("google.com", 443),
]

# Probe target for DNS poisoning test (well-known host)
DNS_TEST_HOST = "cloudflare.com"
DOH_URL = "https://cloudflare-dns.com/dns-query"


def _tcp_connect(host: str, port: int, timeout: float = 5.0) -> tuple[bool, float, Optional[str]]:
    """Try TCP connect. Returns (success, elapsed_sec, error_type)."""
    t0 = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            pass
        return True, time.monotonic() - t0, None
    except ConnectionRefusedError:
        return False, time.monotonic() - t0, "refused"
    except ConnectionResetError:
        return False, time.monotonic() - t0, "rst"
    except socket.timeout:
        return False, time.monotonic() - t0, "timeout"
    except OSError as e:
        err = "rst" if "Connection reset" in str(e) else "error"
        return False, time.monotonic() - t0, err


def _http_get_snippet(host: str, port: int = 80, timeout: float = 5.0) -> tuple[int, str, Optional[str]]:
    """HTTP GET, return (status_code, body_lower_snippet, error)."""
    try:
        url = f"http://{host}:{port}/"
        req = urllib.request.Request(url, headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0",
            "Accept": "text/html,*/*",
        })
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read(2048).decode("utf-8", errors="replace").lower()
            return r.status, body, None
    except urllib.error.HTTPError as e:
        body = e.read(2048).decode("utf-8", errors="replace").lower() if e.fp else ""
        return e.code, body, None
    except urllib.error.URLError as e:
        reason = str(e.reason)
        if "Connection refused" in reason:
            return 0, "", "refused"
        if "timed out" in reason or "timeout" in reason.lower():
            return 0, "", "timeout"
        return 0, "", reason
    except Exception as e:
        return 0, "", str(e)


def _https_head(host: str, port: int = 443, timeout: float = 8.0) -> tuple[bool, float, Optional[str]]:
    """HTTPS HEAD. Returns (success, elapsed_sec, error_str)."""
    t0 = time.monotonic()
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                ssock.send(f"HEAD / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
                ssock.recv(512)
        return True, time.monotonic() - t0, None
    except ssl.SSLError as e:
        return False, time.monotonic() - t0, f"ssl:{e.reason}"
    except ConnectionResetError:
        return False, time.monotonic() - t0, "rst"
    except socket.timeout:
        return False, time.monotonic() - t0, "timeout"
    except Exception as e:
        return False, time.monotonic() - t0, str(e)


def _resolve_doh(host: str, timeout: float = 4.0) -> list[str]:
    """Resolve host via Cloudflare DoH, return list of A record IPs."""
    try:
        url = f"{DOH_URL}?name={host}&type=A"
        req = urllib.request.Request(url, headers={"Accept": "application/dns-json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.loads(r.read(4096))
        return [a["data"] for a in data.get("Answer", []) if a.get("type") == 1]
    except Exception:
        return []


def _resolve_system(host: str) -> list[str]:
    """Resolve host via system DNS."""
    try:
        return list({r[4][0] for r in socket.getaddrinfo(host, None, socket.AF_INET)})
    except Exception:
        return []


def _match_stub(body: str) -> Optional[str]:
    for m in STUB_MARKERS:
        if m in body:
            return m
    return None


def detect(targets=None, timeout_tcp: float = 5.0) -> dict:
    """
    Run DPI detection probe sequence.
    Returns a dict with keys:
      block_type, reason_code, confidence, evidence (list), stage_results (list),
      block_page_body, tested_at
    """
    if targets is None:
        targets = DEFAULT_TARGETS

    result = {
        "block_type": "none",
        "reason_code": "ok",
        "confidence": 0.2,
        "evidence": [],
        "stage_results": [],
        "block_page_body": "",
        "tested_at": int(time.time()),
    }

    # Pick first HTTPS target
    host, port = targets[0] if targets else ("1.1.1.1", 443)

    # ── Stage 0: DNS poisoning check ─────────────────────────────────────────
    if not _is_ip(host):
        sys_addrs = set(_resolve_system(host))
        doh_addrs = set(_resolve_doh(host))
        if sys_addrs and doh_addrs and sys_addrs.isdisjoint(doh_addrs):
            stage = {
                "stage": "dns_compare", "success": False,
                "reason_code": "dns_mismatch",
                "detail": f"Системный DNS {sorted(sys_addrs)} ≠ DoH {sorted(doh_addrs)} — вероятна подмена DNS",
                "confidence": 0.75,
            }
            result["stage_results"].append(stage)
            result["evidence"].append(stage["detail"])
            # DNS poisoning — high confidence if sys DNS gives completely different IPs
            result["block_type"] = "dns"
            result["reason_code"] = "dns_mismatch"
            result["confidence"] = 0.75
            # Don't return yet — continue other probes for completeness
        elif not sys_addrs and doh_addrs:
            stage = {
                "stage": "dns_compare", "success": False,
                "reason_code": "dns_poisoned",
                "detail": f"Системный DNS не разрешает {host}, DoH разрешает {sorted(doh_addrs)} — DNS заблокирован",
                "confidence": 0.9,
            }
            result["stage_results"].append(stage)
            result["block_type"] = "dns"
            result["reason_code"] = "dns_poisoned"
            result["confidence"] = 0.9
            result["evidence"].append(stage["detail"])
        else:
            result["stage_results"].append({
                "stage": "dns_compare", "success": True,
                "reason_code": "ok",
                "detail": f"DNS OK: {sorted(sys_addrs or doh_addrs)}",
                "confidence": 0.8,
            })

    # ── Stage 1: TCP connect ──────────────────────────────────────────────────
    tcp_ok, tcp_elapsed, tcp_err = _tcp_connect(host, port, timeout=timeout_tcp)
    if not tcp_ok:
        if tcp_err == "rst":
            if tcp_elapsed < 0.2:
                reason = "tcp_rst_fast"
                detail = f"TCP RST за {tcp_elapsed*1000:.0f}мс — DPI-инъекция RST (сигнатурная блокировка)"
                conf = 0.9
            else:
                reason = "tcp_rst"
                detail = f"TCP RST за {tcp_elapsed*1000:.0f}мс — жёсткая TCP блокировка"
                conf = 0.8
            block_type = "protocol" if tcp_elapsed < 0.2 else "tcp"
        elif tcp_err == "timeout":
            reason = "tcp_timeout"
            detail = f"TCP таймаут через {tcp_elapsed*1000:.0f}мс — IP/порт заблокирован"
            conf = 0.7
            block_type = "tcp"
        elif tcp_err == "refused":
            reason = "tcp_refused"
            detail = f"TCP REFUSED — порт закрыт (не DPI)"
            conf = 0.3
            block_type = "none"
        else:
            reason = "tcp_error"
            detail = f"TCP ошибка: {tcp_err}"
            conf = 0.5
            block_type = "tcp"

        result["stage_results"].append({
            "stage": "tcp_connect", "success": False,
            "reason_code": reason, "latency_ms": int(tcp_elapsed * 1000),
            "detail": detail, "confidence": conf,
        })
        if block_type != "none":
            result["block_type"] = block_type
            result["reason_code"] = reason
            result["confidence"] = conf
            result["evidence"].append(detail)
        return result

    result["stage_results"].append({
        "stage": "tcp_connect", "success": True,
        "reason_code": "ok", "latency_ms": int(tcp_elapsed * 1000),
        "detail": f"TCP подключение OK за {tcp_elapsed*1000:.0f}мс",
        "confidence": 0.9,
    })
    result["evidence"].append(f"TCP OK за {tcp_elapsed*1000:.0f}мс")

    # ── Stage 2: HTTP probe + stub page detection ─────────────────────────────
    http_status, http_body, http_err = _http_get_snippet(host, 80)
    http_ok = http_err is None and http_status > 0
    if http_ok:
        marker = _match_stub(http_body)
        if http_status == 451:
            result["stage_results"].append({
                "stage": "http_probe", "success": False,
                "reason_code": "http_451",
                "detail": "HTTP 451 — явная блокировка по закону (Unavailable For Legal Reasons)",
                "confidence": 0.95,
            })
            result["block_type"] = "http"
            result["reason_code"] = "http_451"
            result["confidence"] = 0.95
            result["block_page_body"] = http_body[:500]
            result["evidence"].append("HTTP 451 — легальная блокировка")
            return result
        elif marker:
            result["stage_results"].append({
                "stage": "http_probe", "success": False,
                "reason_code": "http_stub",
                "detail": f"Заглушка провайдера обнаружена (маркер: «{marker}»)",
                "confidence": 0.9,
            })
            result["block_type"] = "http"
            result["reason_code"] = "http_stub"
            result["confidence"] = 0.9
            result["block_page_body"] = http_body[:500]
            result["evidence"].append(f"Страница-заглушка РКН: маркер «{marker}»")
            return result
        else:
            result["stage_results"].append({
                "stage": "http_probe", "success": True,
                "reason_code": "ok",
                "detail": f"HTTP {http_status} OK",
                "confidence": 0.8,
            })
            result["evidence"].append(f"HTTP {http_status} OK")
    else:
        result["stage_results"].append({
            "stage": "http_probe", "success": False,
            "reason_code": "http_error",
            "detail": f"HTTP недоступен: {http_err}",
            "confidence": 0.5,
        })

    # ── Stage 3: HTTPS / TLS ──────────────────────────────────────────────────
    tls_ok, tls_elapsed, tls_err = _https_head(host, port, timeout=8.0)
    if not tls_ok:
        if tls_err and "rst" in tls_err.lower():
            conf = 0.75 if http_ok else 0.5
            detail = f"HTTPS RST пока TCP работает — TLS-fingerprint блокировка"
            reason = "tls_rst"
        elif tls_err and "timeout" in tls_err.lower():
            conf = 0.65 if http_ok else 0.45
            detail = f"HTTPS таймаут пока TCP работает — DPI тормозит TLS"
            reason = "tls_timeout"
        elif tls_err and "ssl:" in str(tls_err):
            conf = 0.9
            detail = f"Ошибка сертификата/TLS — не DPI: {tls_err}"
            reason = "tls_cert_error"
        else:
            conf = 0.55
            detail = f"HTTPS ошибка: {tls_err}"
            reason = "tls_error"

        result["stage_results"].append({
            "stage": "https_head", "success": False,
            "reason_code": reason, "latency_ms": int(tls_elapsed * 1000),
            "detail": detail, "confidence": conf,
        })
        if reason not in ("tls_cert_error",):
            result["block_type"] = "tls"
            result["reason_code"] = reason
            result["confidence"] = conf
            result["evidence"].append(detail)
        return result

    result["stage_results"].append({
        "stage": "https_head", "success": True,
        "reason_code": "ok", "latency_ms": int(tls_elapsed * 1000),
        "detail": f"HTTPS OK за {tls_elapsed*1000:.0f}мс",
        "confidence": 0.9,
    })
    result["evidence"].append(f"HTTPS OK за {tls_elapsed*1000:.0f}мс")

    # ── Stage 4: Timing analysis (TSPU throttle detection) ───────────────────
    if tcp_elapsed > 0.05 and tls_elapsed > 0:
        ratio = tls_elapsed / tcp_elapsed
        if ratio > 5.0:
            conf = min(0.7, 0.5 + (ratio - 5.0) * 0.05)
            detail = (f"TLS/TCP соотношение {ratio:.1f}x "
                      f"(TCP={tcp_elapsed*1000:.0f}мс, TLS={tls_elapsed*1000:.0f}мс) — "
                      "ТСПУ искусственно замедляет TLS")
            result["stage_results"].append({
                "stage": "timing_analysis", "success": False,
                "reason_code": "timing_throttle",
                "latency_ms": int(tls_elapsed * 1000),
                "detail": detail, "confidence": conf,
            })
            result["block_type"] = "tls"
            result["reason_code"] = "tls_throttle"
            result["confidence"] = conf
            result["evidence"].append(detail)
            return result

    # All clear
    if result["block_type"] == "none":
        result["reason_code"] = "ok"
        result["confidence"] = 0.9 if http_ok else 0.75
        result["evidence"].append("DPI блокировка не обнаружена")

    return result


def load_cached(state_dir: str = "/run/ltemod") -> Optional[dict]:
    """Load last saved DPI result from state dir."""
    p = Path(state_dir) / "dpi_detection.json"
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except Exception:
        return None


def save_result(result: dict, state_dir: str = "/run/ltemod") -> None:
    """Save DPI result to state dir."""
    Path(state_dir).mkdir(parents=True, exist_ok=True)
    p = Path(state_dir) / "dpi_detection.json"
    p.write_text(json.dumps(result, ensure_ascii=False, indent=2))


def _is_ip(host: str) -> bool:
    try:
        socket.inet_aton(host)
        return True
    except socket.error:
        return False


# Human-readable block type labels
BLOCK_LABELS = {
    "none": ("Блокировок не обнаружено", "text-green-400"),
    "dns": ("DNS блокировка / подмена", "text-red-400"),
    "tcp": ("TCP блокировка (IP/порт)", "text-red-400"),
    "http": ("HTTP DPI / заглушка РКН", "text-red-400"),
    "tls": ("TLS DPI / замедление ТСПУ", "text-yellow-400"),
    "protocol": ("Сигнатура VPN протокола", "text-red-400"),
}
