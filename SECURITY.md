# Keamanan Kredensial

Proyek ini dirancang agar **tidak ada kredensial yang masuk ke git**.

## Prinsip

1. **Semua rahasia hidup di environment variable** — tidak pernah ditulis ke
   file yang di-commit (repo).
2. File `.env` (berisi nilai asli) **dikecualikan lewat `.gitignore`**.
3. Di production (Railway), rahasia diset lewat **Service > Variables**,
   bukan lewat file.
4. `rclone` membaca konfigurasi Dropbox dari env `RCLONE_CONFIG_*` yang
   dibangun saat runtime oleh `entrypoint.sh`.

## Aturan praktis

- JANGAN pernah `git add .env` atau mengirim token ke repo/chat publik.
- Gunakan **refresh token**, bukan access token `sl.` (short-lived, ±4 jam).
- Aktifkan **basic auth** dengan mengisi `REGISTRY_AUTH_USER` dan
  `REGISTRY_AUTH_PASS` agar registry tidak terbuka untuk push/pull publik.
- Jika token pernah bocor: segera revoke di
  [Dropbox App Console](https://www.dropbox.com/developers/apps) lalu buat
  token baru.
- Rotasi kredensial secara berkala.

## Cara mendapatkan refresh token (tanpa menyimpan kredensial di file)

```bash
rclone authorize "dropbox" "<APP_KEY>" "<APP_SECRET>"
```

Perintah ini mencetak blok JSON berisi `refresh_token`. Tempel **seluruh blok
JSON** tersebut ke `DROPBOX_REFRESH_TOKEN` di `.env` (lokal) atau di
Variables Railway (production).
