# EarthLink — Server Deployment

Walkthrough for bringing the EarthLink stack up on a fresh **Ubuntu 24.04 LTS** VPS.

Implements dev-tools backlog items **D10** (OS hardening), **D11** (Docker install),
**D12** (Caddy + Cloudflare Origin CA TLS), **D13** (named volumes),
**D14** (deploy layout), **D15** (systemd unit), **D16** (this doc), and
**D25** (GHCR image publish).

**SSH lockdown (D26)** and **origin lockdown to Cloudflare IP ranges (D27)** are
intentionally separate, later steps — don't run them until your SSH keys are
confirmed working and the stack is up via Cloudflare.

---

## Prerequisites

- Fresh Ubuntu 24.04 LTS VPS, root SSH access available.
- Domain `earthlink.yuxilabs.com` proxied through **Cloudflare** (orange cloud)
  with origin set to `77.68.50.14`. Browser-facing TLS is the existing CF
  universal cert (Google Trust Services); the CF↔origin leg uses a Cloudflare
  Origin CA cert generated below.
- Domain `wt.earthlink.yuxilabs.com` set to **DNS-only** (grey cloud) and
  pointed to `77.68.50.14` for direct WebTransport QUIC on UDP/4433.
- Cloudflare SSL/TLS mode set to **Full (strict)**.
- A GitHub Personal Access Token with `read:packages` (so the server can pull
  the `earthlink-server` image from GHCR).

---

## Resulting filesystem footprint

The host stays minimal. Everything else lives inside Docker.

```
/home/earthlink/
├── docker-compose.prod.yml
├── .env                      (chmod 600)
├── Caddyfile
└── certs/
    ├── origin.pem            (Cloudflare Origin CA cert)
    └── origin.key            (chmod 600)

/etc/systemd/system/
└── earthlink-stack.service

/var/lib/docker/volumes/      (Docker-managed — never touch directly)
├── earthlink_postgres/
├── earthlink_redis/
├── earthlink_chroma/
├── earthlink_caddy_data/
└── earthlink_caddy_config/
```

No source code on the server. The `earthlink-server` image is pulled from GHCR.

---

## One-time: publish the server image to GHCR

Run from your laptop, in the repo root. Requires `docker login ghcr.io` first.

```bash
docker buildx build \
  --platform linux/amd64 \
  --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" \
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t ghcr.io/wsucauid798/earthlink-server:latest \
  -t ghcr.io/wsucauid798/earthlink-server:sha-$(git rev-parse --short HEAD) \
  --push \
  earthlink-server/
```

The `org.opencontainers.image.source` label baked into the Dockerfile auto-links
the package to the `wsucauid798/earthlink-server` repo on GitHub — once pushed,
it appears under the repo's "Packages" sidebar instead of being a loose
user-level package.

Make the package public on GitHub (Packages → `earthlink-server` → Settings → Change visibility),
or keep private and ensure the server's `docker login ghcr.io` PAT has `read:packages`.

---

## Server steps

### 1. Bootstrap the OS (D10 + D11 + docker network)

```bash
ssh root@77.68.50.14

# Either curl from GitHub once the repo is public…
curl -fsSL https://raw.githubusercontent.com/wsucauid798/earthlink/main/deploy/bootstrap.sh \
  -o /root/bootstrap.sh

# …or scp from your laptop:
#   scp deploy/bootstrap.sh root@77.68.50.14:/root/bootstrap.sh

chmod +x /root/bootstrap.sh
/root/bootstrap.sh
```

This installs Docker + compose plugin, configures kernel/swap/UFW/unattended-upgrades,
creates the `earthlink` deploy user, and creates the `earthlink` Docker network.

**SSH is intentionally NOT locked down here.** See step 6.

### 2. Become the deploy user

```bash
sudo -iu earthlink
```

### 3a. Generate the Cloudflare Origin CA cert

In the Cloudflare dashboard for `yuxilabs.com`:

1. **SSL/TLS → Origin Server → Create Certificate**
2. Hostnames: `earthlink.yuxilabs.com` (or `*.yuxilabs.com` to cover future subdomains too)
3. Key type: **ECDSA**
4. Validity: **15 years**
5. Save the **certificate** as `origin.pem` and the **private key** as `origin.key` —
   the key is shown only once, store it carefully.

Then set the zone's TLS posture:

- **SSL/TLS → Overview → Encryption mode** = **Full (strict)**

This is what makes Cloudflare validate the origin cert before forwarding traffic
to the VPS.

### 3b. Place runtime files in `/home/earthlink/` (D14)

From your laptop:

```bash
scp deploy/docker-compose.prod.yml earthlink@77.68.50.14:~/
scp deploy/Caddyfile               earthlink@77.68.50.14:~/
scp deploy/.env.example            earthlink@77.68.50.14:~/.env

# Cloudflare Origin CA cert + key
ssh earthlink@77.68.50.14 'mkdir -p ~/certs && chmod 700 ~/certs'
scp origin.pem  earthlink@77.68.50.14:~/certs/origin.pem
scp origin.key  earthlink@77.68.50.14:~/certs/origin.key
```

On the server (still as `earthlink`):

```bash
cd ~
chmod 600 .env certs/origin.key
chmod 644 certs/origin.pem

# Edit .env to set:
#   POSTGRES_PASSWORD=<a long random string>
#   GHCR_OWNER=wsucauid798            (your GitHub username — owner of the GHCR package)
#   EARTHLINK_SERVER_TAG=latest       (or pin to a sha-<short> / vX.Y.Z)
#   EARTHLINK_WT_PUBLIC_URL=https://wt.earthlink.yuxilabs.com/wt/world
nano .env
```

### 4. Authenticate with GHCR (so the server can pull the image)

```bash
echo "<YOUR_GHCR_PAT>" | docker login ghcr.io -u <gh-username> --password-stdin
```

Verify the image is reachable:

```bash
docker compose -f docker-compose.prod.yml pull
```

### 5. Install + enable the systemd unit (D15)

Back as a sudoer (e.g. exit from the `earthlink` shell, or use a second SSH session):

```bash
sudo cp /home/earthlink/earthlink-stack.service /etc/systemd/system/
# (or scp it directly to /etc/systemd/system/ from your laptop)

sudo systemctl daemon-reload
sudo systemctl enable --now earthlink-stack.service
```

### Verify

```bash
systemctl status earthlink-stack
sudo -u earthlink docker compose -f /home/earthlink/docker-compose.prod.yml ps
curl -I https://earthlink.yuxilabs.com/api/version
curl -s https://earthlink.yuxilabs.com/api/version | jq .
```

No Let's Encrypt issuance happens — Caddy uses the Cloudflare Origin CA cert
mounted from `/home/earthlink/certs/`. If `curl` to `https://earthlink.yuxilabs.com`
fails with a TLS error, double-check Cloudflare's SSL/TLS mode is **Full (strict)**
and that the cert files match the Origin CA cert generated in the dashboard.
`/api/version` should return a `webtransport.url` matching
`https://wt.earthlink.yuxilabs.com/wt/world`.

### 6. SSH lockdown (D26 — only after keys confirmed working)

Once your SSH keys work and you've successfully logged in without a password
**at least once**, run:

```bash
sudo deploy/ssh-lockdown.sh   # script lands separately under D26
```

This disables password authentication and root login, and restarts `sshd`.

---

## Updating the server image

From your laptop, after a code change:

```bash
docker buildx build \
  --platform linux/amd64 \
  --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" \
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t ghcr.io/wsucauid798/earthlink-server:latest \
  -t ghcr.io/wsucauid798/earthlink-server:sha-$(git rev-parse --short HEAD) \
  --push \
  earthlink-server/
```

On the server:

```bash
sudo systemctl restart earthlink-stack
```

The systemd unit re-runs `docker compose pull` then `up -d`, so the server picks
up the new image cleanly.

---

## Backups (D18, lands later)

Until D18 is implemented, take an ad-hoc Postgres dump with:

```bash
sudo -u earthlink docker compose -f /home/earthlink/docker-compose.prod.yml \
  exec -T db pg_dumpall -U earthlink \
  | gzip > "earthlink-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
```

D18 will automate this on a `systemd` timer, pushing to MinIO (D17).
