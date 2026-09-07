# Container Image Hosting — nginx + Docker Registry + Dropbox Storage

**Hosting container image "gratis"** dengan **nginx** sebagai komponen utama
(reverse proxy & HTTP server), **Docker Registry v2** sebagai mesin
pull/push, dan **Dropbox** sebagai storage/backup. Dioptimalkan untuk
deployment di **Railway**.

> ⚠️ **Status kredensial (dicek 2026-09-07):** access token Dropbox berawalan
> `sl.` bersifat *short-lived* (±4 jam) dan **sudah kadaluarsa** (HTTP 401).
> Untuk sinkronisasi otomatis, isi `DROPBOX_REFRESH_TOKEN` dengan *refresh
> token* (lihat bagian [Konfigurasi Dropbox](#konfigurasi-dropbox)).

---

## Arsitektur

Satu image (single container) berisi tiga proses:

```
                          ┌─────────────────────────────────────┐
                          │            Container                │
docker pull / push ──────▶│  nginx (port 80 / $PORT)            │
                          │    │ reverse proxy                  │
                          │    ▼                                │
                          │  Docker Registry v2 (port 5000)     │
                          │    │ baca/tulis blobs                │
                          │    ▼                                │
                          │  /data (volume / ephemeral)         │
                          │    │ sync loop (rclone)             │
                          │    ▼                                │
                          │  Dropbox (durable storage)          │
                          └─────────────────────────────────────┘
```

**Kenapa bukan `rclone mount`?** Railway (dan hampir semua platform gratis)
**tidak mengizinkan FUSE / privileged mode**, sehingga mount filesystem tidak
akan jalan. Pola yang dipakai di sini adalah **sync** (periodik
`local -> Dropbox` + restore saat start), yang bekerja di mana saja tanpa
privilege.

- **nginx** — reverse proxy + endpoint publik (`/v2/...`), optional basic auth.
- **Docker Registry v2** (`registry:2.8`) — engine penyimpanan OCI images.
- **rclone** — sinkronisasi `/data` ⇄ Dropbox.
- **Dropbox** — durable storage / backup blob registry.

---

## Fitur

- ✅ `docker push` / `docker pull` langsung ke registry pribadi.
- ✅ nginx reverse proxy (komponen utama, sesuai permintaan).
- ✅ Storage Dropbox via rclone sync (tanpa FUSE/mount).
- ✅ Semua kredensial **environment variable**, aman & mudah diedit.
- ✅ Basic auth opsional untuk melindungi registry.
- ✅ Health check `/healthz` (untuk Railway & Docker).
- ✅ Restore otomatis saat volume kosong; sync berkala + sync akhir saat
  shutdown.

---

## Struktur repo

```
.
├── Dockerfile              # multi-stage: registry + rclone + nginx
├── entrypoint.sh           # setup env, restore, jalankan proses, sync loop
├── sync.sh                 # sinkronisasi /data -> Dropbox
├── check_dropbox.sh        # validasi kredensial Dropbox
├── nginx/
│   ├── nginx.conf
│   └── conf.d/default.conf # vhost reverse proxy + /healthz
├── registry/config.yml     # konfigurasi registry (filesystem /data)
├── docker-compose.yml      # untuk development lokal
├── railway.json            # konfigurasi deploy Railway
├── .env.example            # template variabel (aman di-commit)
├── .env                    # nilai asli (TER-GITIGNORE, jangan commit)
├── .gitignore
├── .dockerignore
└── SECURITY.md             # panduan keamanan kredensial
```

---

## Konfigurasi Dropbox

### 1. Siapkan App di Dropbox

1. Buka <https://www.dropbox.com/developers/apps> → **Create app**.
2. Pilih **Scoped access** → **App folder** (atau Full Dropbox).
3. Salin **App key** dan **App secret**.
4. Pada tab **Permissions**, beri scope: `files.content.read`,
   `files.content.write`, `files.metadata.read`.
5. (Opsional) Buat access token `sl.` untuk uji cepat — ingat, hanya ±4 jam.

### 2. Buat refresh token (WAJIB untuk sync)

Jalankan di komputer Anda:

```bash
rclone authorize "dropbox" "<APP_KEY>" "<APP_SECRET>"
```

Tempel **seluruh blok JSON** hasil cetakannya ke variabel
`DROPBOX_REFRESH_TOKEN` (bisa di `.env` lokal atau di Variables Railway).

### 3. Isi variabel

```bash
cp .env.example .env
```

Lalu isi nilai di `.env`:

| Variabel | Deskripsi |
| --- | --- |
| `DROPBOX_APP_KEY` | App key Dropbox |
| `DROPBOX_APP_SECRET` | App secret Dropbox |
| `DROPBOX_REFRESH_TOKEN` | Blok JSON refresh token (untuk sync) |
| `DROPBOX_ACCESS_TOKEN` | (Opsional) token `sl.` untuk uji cepat |
| `DROPBOX_PATH` | Folder tujuan di Dropbox (default `container-images`) |
| `REGISTRY_AUTH_USER` / `REGISTRY_AUTH_PASS` | (Opsional) basic auth |
| `SYNC_INTERVAL_SECONDS` | Interval backup ke Dropbox (default 300) |

Cek kredensial Anda:

```bash
./check_dropbox.sh
```

---

## Deployment

### A. Railway (target utama)

1. Push repo ini ke GitHub/GitLab **private** (lihat bagian di bawah).
2. Di Railway: **New Project → Deploy from GitHub repo** (pilih repo ini).
3. Buka tab **Variables** dan tambahkan semua variabel dari `.env`:
   - `DROPBOX_APP_KEY`, `DROPBOX_APP_SECRET`, `DROPBOX_REFRESH_TOKEN`,
     `DROPBOX_PATH`, `REGISTRY_AUTH_USER`, `REGISTRY_AUTH_PASS`,
     `SYNC_INTERVAL_SECONDS`.
4. Railway otomatis menyuntikkan `PORT` — nginx akan listen di `$PORT`.
5. Buat **Volume** dan pasang ke path `/data` (agar blob tetap tersimpan
   antar-restart; Dropbox tetap jadi backup).
6. Deploy. Pastikan healthcheck `/healthz` hijau.

### B. Docker (lokal / VPS)

```bash
docker compose up -d --build
# atau
docker build -t container-image-hosting .
docker run -d --env-file .env -p 8080:80 -v registry_data:/data container-image-hosting
```

---

## Pemakaian

Setelah service berjalan (misal di `https://<project>.up.railway.app`):

```bash
# login (hanya jika basic auth diaktifkan)
docker login <REGISTRY_HOST> -u <user> -p <pass>

# pull image yang sudah di-push
docker pull <REGISTRY_HOST>/namaimage:tag

# push image lokal ke registry Anda
docker tag myimage:latest <REGISTRY_HOST>/myimage:latest
docker push <REGISTRY_HOST>/myimage:latest
```

> Untuk **push** yang aman di production, pastikan endpoint memakai **HTTPS**
> (Railway sudah menyediakan TLS lewat domainnya) atau konfigurasi
> `insecure-registries` di daemon Docker Anda jika memakai HTTP biasa.

---

## Membuat repo private & push (instruksi)

1. Buat repo **private** baru di GitHub/GitLab.
2. Inisialisasi & push:

```bash
cd container-image-hosting
git init
git add .
git commit -m "Initial commit: nginx + registry + Dropbox storage"
git branch -M main
git remote add origin https://github.com/<USERNAME>/<REPO>.git
git push -u origin main
```

> Pastikan `.env` TIDAK ikut ter-push (sudah di-`.gitignore`).

---

## Catatan & batasan

- **Railway free tier**: tanpa volume, storage `/data` bersifat ephemeral dan
  akan hilang saat redeploy/restart. Dropbox berfungsi sebagai pemulihan
  (restore otomatis saat start).
- **Dropbox API rate limit**: sync tiap `SYNC_INTERVAL_SECONDS` memakai
  bandwidth/API quota; sesuaikan interval untuk repo aktif.
- Token `sl.` short-lived — selalu gunakan refresh token untuk otomatisasi.
- Untuk produksi yang lebih serius, pertimbangkan menambahkan auth token
  (HTTP basic) atau solusi auth registry lain.

## Lisensi

MIT — lihat file `LICENSE`.
