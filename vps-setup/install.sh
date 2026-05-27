#!/usr/bin/env bash
# EarthLink runtime install — places files into /home/earthlink/, installs the
# systemd unit, and starts the stack.
#
# Pre-conditions:
#   - bootstrap.sh has run successfully (earthlink user exists, docker installed)
#   - The following files have been scp'd to /tmp on this host:
#       /tmp/docker-compose.prod.yml      (required)
#       /tmp/Caddyfile                    (required)
#       /tmp/Dockerfile.caddy             (required)
#       /tmp/install.sh                   (this script — required)
#
# Optional staged files (script falls back to existing on-disk versions if
# absent — useful for re-runs that only update compose/caddy/dockerfile):
#       /tmp/.env                         (used if present, else keeps $DEST/.env)
#       /tmp/earthlink.yuxilabs.com.pem   (cert, falls back to $DEST/certs/origin.pem)
#       /tmp/earthlink.yuxilabs.com.key   (key,  falls back to $DEST/certs/origin.key)
#       /tmp/earthlink-stack.service      (unit, falls back to existing $SYSTEMD_UNIT)
#
# Optional environment variables (passed by the caller of this script):
#       CF_API_TOKEN — appended/updated in $DEST/.env if set; needed by Caddy's
#                      cloudflare DNS plugin to obtain LE certs via DNS-01.
# Optional file fallback (for callers who can't preserve env across sudo):
#       /tmp/cf_api_token — single-line file containing the token. Read iff
#                           CF_API_TOKEN is not already in the environment.
#                           Removed after use.
#
# Run as root:
#   sudo bash /tmp/install.sh
#
# Idempotent. Re-running re-applies file ownership/perms and reloads systemd.

set -Eeuo pipefail

SERVICE_USER="${SERVICE_USER:-earthlink}"
SRC="${SRC:-/tmp}"
DEST="/home/${SERVICE_USER}"
SYSTEMD_UNIT="/etc/systemd/system/earthlink-stack.service"
LOG_FILE="${LOG_FILE:-/var/log/earthlink-install.log}"

# --- Sanity ----------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

# --- Logging ---------------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

printf '\n##############################################################\n'
printf '# install run started: %s (UTC)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '# service user=%s  src=%s  dest=%s\n' "$SERVICE_USER" "$SRC" "$DEST"
printf '##############################################################\n\n'

# --- Error trap ------------------------------------------------------------

trap 'rc=$?; printf "\nERROR: install failed at line %d (exit %d)\n  command: %s\n  see: %s\n" \
  "$LINENO" "$rc" "$BASH_COMMAND" "$LOG_FILE" >&2; exit $rc' ERR

# --- Helpers ---------------------------------------------------------------

step()   { printf '\n=== %s ===\n' "$*"; }
verify() {
  local desc="$1"; shift
  if ! "$@" >/dev/null 2>&1; then
    printf 'verify FAILED: %s\n  command: %s\n' "$desc" "$*" >&2
    return 1
  fi
  printf '  verified: %s\n' "$desc"
}

# Place a file with given perms iff its source exists. Returns 0 either way.
# Pre-existing destination is left intact when source is absent — enables
# partial re-deploys (e.g. update only compose + Caddyfile).
maybe_install() {
  local mode="$1" owner="$2" src="$3" dest="$4" desc="$5"
  if [[ -s "$src" ]]; then
    install -m "$mode" -o "$owner" -g "$owner" "$src" "$dest"
    printf '  placed: %s -> %s\n' "$desc" "$dest"
  elif [[ -s "$dest" ]]; then
    printf '  kept existing: %s (no fresh source at %s)\n' "$dest" "$src"
  else
    printf 'verify FAILED: no source AND no existing target for %s\n' "$desc" >&2
    printf '  source: %s\n  target: %s\n' "$src" "$dest" >&2
    return 1
  fi
}

# --- Preconditions ---------------------------------------------------------

step "Preconditions"
verify "$SERVICE_USER user exists"  id -u "$SERVICE_USER"
verify "docker present"             command -v docker
verify "earthlink network exists"   docker network inspect earthlink

# Hard requirements (always staged in /tmp by the caller):
for f in docker-compose.prod.yml Caddyfile Dockerfile.caddy; do
  verify "staging file present: $SRC/$f" test -s "$SRC/$f"
done

# --- Place runtime files ---------------------------------------------------

step "Place compose + Caddyfile + Dockerfile.caddy -> $DEST/"
install -m 0644 -o "$SERVICE_USER" -g "$SERVICE_USER" \
  "$SRC/docker-compose.prod.yml" "$DEST/docker-compose.prod.yml"
install -m 0644 -o "$SERVICE_USER" -g "$SERVICE_USER" \
  "$SRC/Caddyfile" "$DEST/Caddyfile"
install -m 0644 -o "$SERVICE_USER" -g "$SERVICE_USER" \
  "$SRC/Dockerfile.caddy" "$DEST/Dockerfile.caddy"

step "Place .env (optional staging) -> $DEST/"
maybe_install 0600 "$SERVICE_USER" "$SRC/.env" "$DEST/.env" ".env"

step "Place certs -> $DEST/certs/"
install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DEST/certs"
maybe_install 0644 "$SERVICE_USER" \
  "$SRC/earthlink.yuxilabs.com.pem" "$DEST/certs/origin.pem" "origin.pem"
maybe_install 0600 "$SERVICE_USER" \
  "$SRC/earthlink.yuxilabs.com.key" "$DEST/certs/origin.key" "origin.key"

# --- CF_API_TOKEN injection (idempotent) -----------------------------------
# If the caller passed CF_API_TOKEN in the environment, ensure it's present
# in $DEST/.env. Append on first set; replace value on subsequent runs.

# Fall back to a /tmp file if env wasn't preserved across sudo.
if [[ -z "${CF_API_TOKEN:-}" && -s "$SRC/cf_api_token" ]]; then
  CF_API_TOKEN="$(tr -d '\r\n' < "$SRC/cf_api_token")"
  rm -f "$SRC/cf_api_token"
fi

if [[ -n "${CF_API_TOKEN:-}" ]]; then
  step "Set CF_API_TOKEN in $DEST/.env"
  if [[ ! -s "$DEST/.env" ]]; then
    install -m 0600 -o "$SERVICE_USER" -g "$SERVICE_USER" /dev/null "$DEST/.env"
  fi
  if grep -q '^CF_API_TOKEN=' "$DEST/.env"; then
    sed -i "s|^CF_API_TOKEN=.*|CF_API_TOKEN=${CF_API_TOKEN}|" "$DEST/.env"
    printf '  updated CF_API_TOKEN (in-place)\n'
  else
    printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN" >> "$DEST/.env"
    printf '  appended CF_API_TOKEN\n'
  fi
  chown "$SERVICE_USER:$SERVICE_USER" "$DEST/.env"
  chmod 600 "$DEST/.env"
fi

# --- Verify file perms -----------------------------------------------------

step "Verify file ownership + permissions"
verify ".env mode 600"                  bash -c "[[ \$(stat -c %a '$DEST/.env') -eq 600 ]]"
verify ".env owned by $SERVICE_USER"    bash -c "[[ \$(stat -c %U '$DEST/.env') == '$SERVICE_USER' ]]"
verify "origin.key mode 600"            bash -c "[[ \$(stat -c %a '$DEST/certs/origin.key') -eq 600 ]]"
verify "certs/ mode 700"                bash -c "[[ \$(stat -c %a '$DEST/certs') -eq 700 ]]"
verify "Caddyfile present"              test -s "$DEST/Caddyfile"
verify "compose file present"           test -s "$DEST/docker-compose.prod.yml"
verify "Dockerfile.caddy present"       test -s "$DEST/Dockerfile.caddy"

# --- Install systemd unit (optional staging) -------------------------------

step "Install systemd unit (optional staging)"
if [[ -s "$SRC/earthlink-stack.service" ]]; then
  install -m 0644 -o root -g root "$SRC/earthlink-stack.service" "$SYSTEMD_UNIT"
  systemctl daemon-reload
  printf '  installed fresh unit + daemon-reload\n'
elif [[ -s "$SYSTEMD_UNIT" ]]; then
  printf '  kept existing %s (no fresh source)\n' "$SYSTEMD_UNIT"
else
  printf 'verify FAILED: no systemd unit available (neither %s nor %s)\n' \
    "$SRC/earthlink-stack.service" "$SYSTEMD_UNIT" >&2
  exit 1
fi
systemctl enable earthlink-stack.service
verify "earthlink-stack.service enabled" systemctl is-enabled --quiet earthlink-stack.service

# --- Clean up /tmp ---------------------------------------------------------

step "Clean up staged files in $SRC"
rm -f \
  "$SRC/docker-compose.prod.yml" \
  "$SRC/Caddyfile" \
  "$SRC/Dockerfile.caddy" \
  "$SRC/.env" \
  "$SRC/earthlink.yuxilabs.com.pem" \
  "$SRC/earthlink.yuxilabs.com.key" \
  "$SRC/earthlink-stack.service" \
  "$SRC/install.sh"

# --- Start the stack -------------------------------------------------------

step "Start the stack (image pull + caddy build on first run; can take a few min)"
systemctl start earthlink-stack.service
sleep 5
systemctl status earthlink-stack.service --no-pager || true

# --- Final verify ----------------------------------------------------------

step "Final verification"
verify "earthlink-stack enabled" systemctl is-enabled --quiet earthlink-stack.service
verify "earthlink-stack active"  systemctl is-active   --quiet earthlink-stack.service

cat <<EOF

==================================================
Install complete.
Log: $LOG_FILE

Stack containers (give it 1–2 min to fully come up on first run):
  sudo -iu $SERVICE_USER docker compose -f $DEST/docker-compose.prod.yml ps

Public verification (from anywhere):
  curl -I https://earthlink.yuxilabs.com/api/version

systemd journal:
  journalctl -u earthlink-stack.service -f
==================================================
EOF
