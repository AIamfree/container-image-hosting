#!/bin/sh
# =====================================================================
#  Entrypoint: konfigurasi runtime lalu jalankan registry + panel + nginx + sync
#  Semua kredensial dibaca dari ENVIRONMENT VARIABLE (tidak pernah
#  ditulis ke file yang di-commit).
# =====================================================================
set -e

LOG() { echo "[entrypoint] $*"; }

# ---------- 1. Konfigurasi remote Dropbox untuk rclone ----------
# rclone membaca config langsung dari env: RCLONE_CONFIG_<NAME>_<KEY>
HAS_SYNC=0
if [ -n "${DROPBOX_REFRESH_TOKEN:-}" ]; then
  # RCLONE_DROPBOX_TYPE memungkinkan override backend (default: dropbox).
  # Berguna untuk pengujian end-to-end dengan backend mock (mis. "local").
  export RCLONE_CONFIG_DROPBOX_TYPE="${RCLONE_DROPBOX_TYPE:-dropbox}"
  export RCLONE_CONFIG_DROPBOX_CLIENT_ID="${DROPBOX_APP_KEY:-}"
  export RCLONE_CONFIG_DROPBOX_CLIENT_SECRET="${DROPBOX_APP_SECRET:-}"
  export RCLONE_CONFIG_DROPBOX_TOKEN="${DROPBOX_REFRESH_TOKEN}"
  HAS_SYNC=1
  LOG "Dropbox remote terkonfigurasi (refresh token ditemukan)"
else
  LOG "PERINGATAN: DROPBOX_REFRESH_TOKEN kosong -> sinkronisasi Dropbox NONAKTIF (mode lokal saja)"
fi

DROPBOX_PATH="${DROPBOX_PATH:-container-images}"
REMOTE="dropbox:${DROPBOX_PATH}"
LOCAL="${DATA_DIR:-/data}"
SYNC_INTERVAL="${SYNC_INTERVAL_SECONDS:-300}"

mkdir -p "$LOCAL"

# ---------- 2. Basic auth opsional untuk registry (nginx) ----------
AUTH_CONF=/etc/nginx/conf.d/auth.inc
if [ -n "${AUTH_USER:-}" ] && [ -n "${AUTH_PASS:-}" ]; then
  HASH=$(openssl passwd -apr1 "$AUTH_PASS")
  printf '%s:%s\n' "$AUTH_USER" "$HASH" > /etc/nginx/.htpasswd
  chmod 644 /etc/nginx/.htpasswd
  printf 'auth_basic "Container Registry";\nauth_basic_user_file /etc/nginx/.htpasswd;\n' > "$AUTH_CONF"
  LOG "Basic auth registry AKTIF untuk user: ${AUTH_USER}"
else
  : > "$AUTH_CONF"
  LOG "Basic auth registry nonaktif (isi AUTH_USER/PASS untuk mengaktifkan)"
fi

# ---------- 2b. Basic auth untuk control panel (opsional) ----------
PANEL_AUTH_CONF=/etc/nginx/conf.d/auth_panel.inc
if [ -n "${PANEL_PASS:-}" ]; then
  PHASH=$(openssl passwd -apr1 "$PANEL_PASS")
  printf '%s:%s\n' "${PANEL_USER:-admin}" "$PHASH" > /etc/nginx/.htpasswd_panel
  chmod 644 /etc/nginx/.htpasswd_panel
  printf 'auth_basic "Control Panel";\nauth_basic_user_file /etc/nginx/.htpasswd_panel;\n' > "$PANEL_AUTH_CONF"
  LOG "Control panel terlindungi basic auth (user: ${PANEL_USER:-admin})"
else
  : > "$PANEL_AUTH_CONF"
  LOG "PERINGATAN: PANEL_PASS kosong -> control panel TANPA password (set PANEL_PASS untuk mengamankan)"
fi

# ---------- 3. Port listen (Railway menyuntikkan $PORT) ----------
NGINX_CONF=/etc/nginx/conf.d/default.conf
if [ -n "${PORT:-}" ] && [ "$PORT" != "80" ]; then
  if grep -q "listen ${PORT};" "$NGINX_CONF"; then
    LOG "nginx sudah listen di port ${PORT}"
  else
    sed -i "s/listen 80;/listen 80;\n    listen ${PORT};/" "$NGINX_CONF"
    LOG "nginx listen di port 80 + ${PORT}"
  fi
fi

# ---------- 4. Restore storage dari Dropbox jika volume kosong ----------
if [ "$HAS_SYNC" = "1" ]; then
  if [ -z "$(ls -A "$LOCAL" 2>/dev/null)" ]; then
    LOG "Volume kosong -> restore dari ${REMOTE}"
    if rclone copy "$REMOTE" "$LOCAL" --transfers 4 --checkers 8 --log-level ERROR; then
      LOG "Restore selesai"
    else
      LOG "Restore dilewati/gagal (folder Dropbox masih kosong?)"
    fi
  else
    LOG "Volume sudah terisi -> lewati restore"
  fi
fi

# ---------- 5. Jalankan Docker Registry v2 ----------
export REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY="$LOCAL"
export REGISTRY_HTTP_ADDR="${REGISTRY_HTTP_ADDR:-:5000}"
/opt/registry/registry serve /etc/registry/config.yml &
REGISTRY_PID=$!
LOG "Registry berjalan (pid ${REGISTRY_PID}) di ${REGISTRY_HTTP_ADDR}"

# ---------- 5b. Control panel (backend Python stdlib) ----------
if command -v python3 >/dev/null 2>&1; then
  python3 /panel/server.py &
  PANEL_PID=$!
  LOG "Control panel berjalan (pid ${PANEL_PID}) -> buka <host>/_panel/"
else
  LOG "python3 tidak ditemukan -> control panel nonaktif"
fi

# ---------- 6. Loop sinkronisasi berkala: /data -> Dropbox ----------
if [ "$HAS_SYNC" = "1" ]; then
  (
    while true; do
      sleep "$SYNC_INTERVAL"
      /scripts/sync.sh || LOG "sync gagal, akan dicoba lagi dalam ${SYNC_INTERVAL}s"
    done
  ) &
  SYNC_PID=$!
  LOG "Sync loop aktif setiap ${SYNC_INTERVAL}s"
fi

# ---------- 7. Graceful shutdown: sync terakhir + hentikan proses ----------
stop_all() {
  LOG "menghentikan layanan..."
  [ -n "${PANEL_PID:-}" ] && kill "$PANEL_PID" 2>/dev/null || true
  [ -n "${SYNC_PID:-}" ] && kill "$SYNC_PID" 2>/dev/null || true
  if [ "$HAS_SYNC" = "1" ]; then
    /scripts/sync.sh || true
  fi
  kill "$REGISTRY_PID" 2>/dev/null || true
  exit 0
}
trap stop_all TERM INT

# ---------- 8. nginx di foreground ----------
LOG "menjalankan nginx"
exec nginx -g 'daemon off;'
