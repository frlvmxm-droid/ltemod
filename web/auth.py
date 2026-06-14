import hashlib
import os
from pathlib import Path
from functools import wraps
from flask import session, redirect, url_for, request, abort

AUTH_FILE = Path("/etc/ltemod/web-auth")
SECRET_FILE = Path("/etc/ltemod/web-secret")


def get_or_create_secret_key() -> bytes:
    if SECRET_FILE.exists():
        return SECRET_FILE.read_bytes()
    key = os.urandom(32)
    SECRET_FILE.parent.mkdir(parents=True, exist_ok=True)
    SECRET_FILE.write_bytes(key)
    SECRET_FILE.chmod(0o600)
    return key


def check_password(password: str) -> bool:
    if not AUTH_FILE.exists():
        return False
    stored = AUTH_FILE.read_text().strip()
    candidate = hashlib.sha256(password.encode()).hexdigest()
    return hashlib.compare_digest(stored, candidate)


def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("authenticated"):
            if request.path.startswith("/api/"):
                abort(401)
            return redirect(url_for("login", next=request.url))
        return f(*args, **kwargs)
    return decorated
