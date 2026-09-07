#!/bin/sh
# =====================================================================
#  Validasi kredensial Dropbox dari file .env
#  - DROPBOX_ACCESS_TOKEN : dicek via Dropbox API (get_current_account)
#  - DROPBOX_REFRESH_TOKEN: dicek via rclone (jika rclone terpasang)
# =====================================================================
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$DIR/.env" ]; then
  set -a
  . "$DIR/.env"
  set +a
else
  echo "Tidak menemukan .env. Jalankan: cp .env.example .env lalu isi."
  exit 1
fi

echo "App key       : ${DROPBOX_APP_KEY:-<kosong>}"
echo "App secret    : ${DROPBOX_APP_SECRET:-<kosong>}"
echo "Dropbox path  : ${DROPBOX_PATH:-container-images}"
echo

# ---- 1) cek access token (short-lived) via API Dropbox ----
if [ -n "${DROPBOX_ACCESS_TOKEN:-}" ]; then
  echo "-> Mengecek DROPBOX_ACCESS_TOKEN via API Dropbox..."
  code=$(curl -s -o /tmp/dbx_check.json -w '%{http_code}' -X POST \
    https://api.dropboxapi.com/2/users/get_current_account \
    -H "Authorization: Bearer $DROPBOX_ACCESS_TOKEN" \
    -H "Content-Type: application/json" -d '{}')
  echo "   HTTP $code"
  head -c 300 /tmp/dbx_check.json 2>/dev/null; echo
  if [ "$code" = "200" ]; then
    echo "   OK: access token valid."
  else
    echo "   GAGAL: token tidak valid/kadaluarsa (token 'sl.' hanya ±4 jam)."
  fi
  echo
fi

# ---- 2) cek refresh token via rclone ----
if command -v rclone >/dev/null 2>&1; then
  if [ -n "${DROPBOX_REFRESH_TOKEN:-}" ]; then
    export RCLONE_CONFIG_DROPBOX_TYPE=dropbox
    export RCLONE_CONFIG_DROPBOX_CLIENT_ID="${DROPBOX_APP_KEY:-}"
    export RCLONE_CONFIG_DROPBOX_CLIENT_SECRET="${DROPBOX_APP_SECRET:-}"
    export RCLONE_CONFIG_DROPBOX_TOKEN="${DROPBOX_REFRESH_TOKEN}"
    echo "-> Mengecek DROPBOX_REFRESH_TOKEN via rclone..."
    if rclone lsd "dropbox:${DROPBOX_PATH:-container-images}" >/dev/null 2>&1; then
      echo "   OK: refresh token valid, folder Dropbox dapat diakses."
    else
      echo "   GAGAL: rclone tidak bisa mengakses Dropbox (cek token/scope)."
    fi
  else
    echo "   (lewati) DROPBOX_REFRESH_TOKEN kosong."
  fi
else
  echo "   (lewati) rclone tidak terpasang di mesin ini."
fi
