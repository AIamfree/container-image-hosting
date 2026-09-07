#!/usr/bin/env python3
"""
Control panel backend (stdlib only, tanpa dependensi eksternal).

Menyajikan UI web (index.html) + JSON API ringan untuk mengelola layanan:
  GET  /            -> halaman panel
  GET  /api/status  -> status layanan (registry, dropbox, storage, sync)
  GET  /api/images  -> daftar repository + tag dari registry
  POST /api/sync    -> picu sinkronisasi /data -> Dropbox

Bind ke 127.0.0.1 (hanya internal); nginx mereverse-proxy dari /_panel/.
Auth: HTTP Basic (PANEL_USER/PANEL_PASS) bila PANEL_PASS diisi.
"""
import base64
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("PANEL_PORT", "8081"))

PANEL_USER = os.environ.get("PANEL_USER", "admin")
PANEL_PASS = os.environ.get("PANEL_PASS", "")

DROPBOX_PATH = os.environ.get("DROPBOX_PATH", "container-images")
SYNC_INTERVAL = os.environ.get("SYNC_INTERVAL_SECONDS", "300")
DATA_DIR = os.environ.get("REGISTRY_STORAGE_DIR", "/data")

STATE_FILE = os.path.join(DATA_DIR, ".sync_status.json")
SYNC_LOCKDIR = "/tmp/.sync.lockdir"

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
INDEX_FILE = os.path.join(BASE_DIR, "index.html")

REG_ADDR = os.environ.get("REGISTRY_HTTP_ADDR", ":5000")
REG_PORT = REG_ADDR.rsplit(":", 1)[-1]
REG_BASE = "http://127.0.0.1:%s" % REG_PORT

STARTED = time.time()


# ---------- helpers ----------
def read_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def human(n):
    n = float(n)
    if n < 1024:
        return "%d B" % int(n)
    n /= 1024.0
    for unit in ("KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return "%.1f %s" % (n, unit)
        n /= 1024.0
    return "%.1f TB" % n


def du_data():
    try:
        out = subprocess.run(
            ["du", "-sb", DATA_DIR], capture_output=True, text=True, timeout=15
        )
        if out.returncode == 0:
            b = int(out.stdout.split()[0])
            return b, human(b)
    except Exception:
        pass
    return 0, "0 B"


def registry_get(path):
    req = urllib.request.Request(
        REG_BASE + path, headers={"Accept": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=6) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return 0, str(e)


def status_payload():
    code, _ = registry_get("/v2/")
    reg_ok = code in (200, 401)  # 401 = terjangkau tapi minta auth
    b, h = du_data()
    state = read_state()
    sync = {"interval": int(SYNC_INTERVAL or 0)}
    if isinstance(state, dict):
        sync.update(state)
    return {
        "ok": True,
        "time": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "uptime": int(time.time() - STARTED),
        "panel_auth": bool(PANEL_PASS),
        "registry": {"ok": reg_ok, "http": code},
        "dropbox": {
            "configured": bool(os.environ.get("DROPBOX_REFRESH_TOKEN")),
            "path": DROPBOX_PATH,
        },
        "storage": {"bytes": b, "human": h},
        "sync": sync,
        "env": {
            "app_key_set": bool(os.environ.get("DROPBOX_APP_KEY")),
            "app_secret_set": bool(os.environ.get("DROPBOX_APP_SECRET")),
            "refresh_token_set": bool(os.environ.get("DROPBOX_REFRESH_TOKEN")),
            "registry_auth_enabled": bool(
                os.environ.get("REGISTRY_AUTH_USER")
                and os.environ.get("REGISTRY_AUTH_PASS")
            ),
        },
    }


def images_payload():
    code, body = registry_get("/v2/_catalog")
    repos = []
    error = None
    if code != 200:
        error = "registry catalog HTTP %s" % code
    else:
        try:
            repos = json.loads(body).get("repositories", []) or []
        except Exception:
            error = "gagal parse catalog"
    result = []
    for name in repos:
        tc, tb = registry_get("/v2/%s/tags/list" % name)
        tags = []
        if tc == 200:
            try:
                tags = json.loads(tb).get("tags") or []
            except Exception:
                tags = []
        result.append({"name": name, "tags": tags})
    return {"images": result, "count": len(result), "error": error}


def trigger_sync():
    if os.path.exists(SYNC_LOCKDIR):
        return {"ok": False, "error": "sync sedang berjalan", "busy": True}
    started = time.time()
    try:
        proc = subprocess.run(
            ["/scripts/sync.sh"], capture_output=True, text=True, timeout=600
        )
        dur = round(time.time() - started, 1)
        return {
            "ok": proc.returncode == 0,
            "exit": proc.returncode,
            "duration_sec": dur,
            "state": read_state(),
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timeout setelah 600 detik"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ---------- HTTP handler ----------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # senyap
        pass

    def _auth_ok(self):
        if not PANEL_PASS:
            return True
        header = self.headers.get("Authorization", "")
        if header.startswith("Basic "):
            try:
                decoded = base64.b64decode(header[6:]).decode("utf-8", "replace")
                user, _, pw = decoded.partition(":")
                if user == PANEL_USER and pw == PANEL_PASS:
                    return True
            except Exception:
                pass
        return False

    def _send_json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self):
        try:
            with open(INDEX_FILE, "rb") as f:
                body = f.read()
        except Exception:
            body = b"<h1>panel index missing</h1>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _require_auth(self):
        if not self._auth_ok():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="Control Panel"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False
        return True

    def do_GET(self):
        if not self._require_auth():
            return
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self._send_html()
        elif path == "/api/status":
            self._send_json(status_payload())
        elif path == "/api/images":
            self._send_json(images_payload())
        else:
            self._send_json({"error": "not found"}, 404)

    def do_POST(self):
        if not self._require_auth():
            return
        path = self.path.split("?", 1)[0]
        if path == "/api/sync":
            self._send_json(trigger_sync())
        else:
            self._send_json({"error": "not found"}, 404)


def main():
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
    except OSError as e:
        print("[panel] warning: tidak bisa membuat %s: %s" % (DATA_DIR, e), flush=True)
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print("[panel] listening on http://%s:%s" % (HOST, PORT), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
