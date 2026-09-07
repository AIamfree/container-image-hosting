#!/bin/sh
# =====================================================================
#  Sinkronisasi SATU ARAH: /data (lokal, sumber kebenaran) -> Dropbox
#  Dropbox berperan sebagai durable storage / backup.
#  Dipanggil oleh entrypoint (berkala + saat shutdown) dan control panel.
#  Hasilnya dicatat ke /data/.sync_status.json (dibaca control panel).
# =====================================================================

REMOTE="dropbox:${DROPBOX_PATH:-container-images}"
LOCAL="${DATA_DIR:-/data}"
STATE="${LOCAL}/.sync_status.json"

# Lock sederhana (mkdir atomik) agar tidak ada 2 sync bersamaan
LOCKDIR=/tmp/.sync.lockdir
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "sync sudah berjalan, lewati"
  exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Pastikan folder remote ada
rclone mkdir "$REMOTE" 2>/dev/null || true

ERR=$(mktemp)
if rclone sync "$LOCAL" "$REMOTE" \
     --transfers 4 \
     --checkers 8 \
     --log-level ERROR \
     --exclude '.DS_Store' \
     --exclude '.sync_status.json' \
     --exclude '**/_uploads/**' \
     2>"$ERR"; then
  printf '{"last_sync":"%s","ok":true,"error":""}\n' "$DATE" > "$STATE"
  rm -f "$ERR"
  echo "sync OK"
  exit 0
else
  MSG=$(tr '\n' ' ' < "$ERR" | tr -d '"' | cut -c1-300)
  printf '{"last_sync":"%s","ok":false,"error":"%s"}\n' "$DATE" "$MSG" > "$STATE"
  rm -f "$ERR"
  echo "sync GAGAL: $MSG"
  exit 1
fi
