# =====================================================================
#  Container Image Hosting
#  Satu image = nginx (reverse proxy) + Docker Registry v2 + rclone (Dropbox)
#  Target utama: Railway (Dockerfile build). Juga jalan di host Docker mana pun.
# =====================================================================

# ---------- Stage 1: ambil binary registry dari image resmi ----------
FROM registry:2.8 AS registry

# ---------- Stage 2: ambil binary rclone (static) ----------
FROM alpine:3.20 AS rclone
RUN apk add --no-cache curl unzip \
 && curl -fsSL https://downloads.rclone.org/rclone-current-linux-amd64.zip -o /tmp/rclone.zip \
 && unzip -q /tmp/rclone.zip -d /tmp \
 && mv /tmp/rclone-*-linux-amd64/rclone /usr/bin/rclone \
 && chmod +x /usr/bin/rclone \
 && rm -rf /tmp/rclone.zip /tmp/rclone-*-linux-amd64

# ---------- Stage 3: image final ----------
FROM alpine:3.20

# nginx + tools
RUN apk add --no-cache nginx openssl ca-certificates tzdata python3 \
 && mkdir -p /run/nginx /var/log/nginx /var/lib/nginx /data /etc/nginx/conf.d \
 && chown -R nginx:nginx /run/nginx /var/log/nginx /var/lib/nginx

# Binary registry (dari image resmi) + config
COPY --from=registry /bin/registry /opt/registry/registry
COPY registry/config.yml /etc/registry/config.yml

# Binary rclone
COPY --from=rclone /usr/bin/rclone /usr/bin/rclone

# nginx: config utama + vhost
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf
# placeholder include untuk basic-auth (diisi oleh entrypoint saat runtime)
RUN touch /etc/nginx/conf.d/auth.inc /etc/nginx/conf.d/auth_panel.inc

# Scripts
# Control panel (backend Python stdlib + UI)
COPY panel/ /panel/

COPY entrypoint.sh /entrypoint.sh
COPY sync.sh /scripts/sync.sh
RUN chmod +x /entrypoint.sh /scripts/sync.sh

EXPOSE 80 8080
VOLUME ["/data"]

# Healthcheck: nginx selalu listen di port 80 (plus $PORT bila diset Railway)
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1/healthz || exit 1

ENTRYPOINT ["/entrypoint.sh"]
