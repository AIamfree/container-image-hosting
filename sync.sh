#!/bin/sh
# =====================================================================
#  Sinkronisasi SATU ARAH: /data (lokal, sumber kebenaran) -> Dropbox
#  Dropbox berperan sebagai durable storage / backup.
#  Dipanggil secara berkala oleh entrypoint.
# =====================================================================
set -e

REMOTE="dropbox:${DROPBOX_PATH:-container-images}"
LOCAL="${REGISTRY_STORAGE_DIR:-/data}"

# Pastikan folder remote ada
rclone mkdir "$REMOTE" 2>/dev/null || true

rclone sync "$LOCAL" "$REMOTE" \
  --transfers 4 \
  --checkers 8 \
  --log-level ERROR \
  --exclude '.DS_Store'
