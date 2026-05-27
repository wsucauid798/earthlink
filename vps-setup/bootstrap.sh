#!/usr/bin/env bash
# EarthLink VPS bootstrap — Ubuntu 24.04 LTS
#
# Idempotent. Run once on a fresh server as root (or via sudo).
# Implements dev-tools D10 (OS hardening baseline) + D11 (Docker install) +
# the docker network creation referenced by D14 / docker-compose.prod.yml.
#
# SSH lockdown is intentionally NOT done here (deferred to D26 /
# deploy/ssh-lockdown.sh) so initial provisioning cannot lock you out.
#
# Failure handling:
#   - set -Eeuo pipefail  (errors abort, undefined vars abort, pipe failures propagate)
#   - trap ERR            (logs failing line + command before exit)
#   - logging             (everything tee'd to /var/log/earthlink-bootstrap.log)
#   - retry()             (3 attempts with exponential backoff for network ops)
#   - step()              (visible progress markers)
#   - verify()            (post-step checks for things that can silently fail)

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Config (overridable via env)
# ---------------------------------------------------------------------------

ADMIN_USER="${ADMIN_USER:-wsawyerr}"        # interactive admin: SSH key, sudoer, docker group
SERVICE_USER="${SERVICE_USER:-earthlink}"   # service runtime: no shell, no SSH, owns stack files
ADMIN_PUBKEY="${ADMIN_PUBKEY:-}"            # if set, installed into ADMIN_USER's authorized_keys
SWAP_SIZE="${SWAP_SIZE:-8G}"
DOCKER_NETWORK="${DOCKER_NETWORK:-earthlink}"
LOG_FILE="${LOG_FILE:-/var/log/earthlink-bootstrap.log}"

# ---------------------------------------------------------------------------
# Sanity (must run before tee/exec redirection)
# ---------------------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Logging — everything from here on is tee'd to LOG_FILE (append).
# ---------------------------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

printf '\n\n##############################################################\n'
printf '# bootstrap run started: %s (UTC)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '# admin=%s service=%s swap=%s network=%s\n' \
  "$ADMIN_USER" "$SERVICE_USER" "$SWAP_SIZE" "$DOCKER_NETWORK"
printf '##############################################################\n\n'

# ---------------------------------------------------------------------------
# Error trap
# ---------------------------------------------------------------------------

trap 'rc=$?; printf "\nERROR: bootstrap failed at line %d (exit %d)\n  command: %s\n  see: %s\n" \
  "$LINENO" "$rc" "$BASH_COMMAND" "$LOG_FILE" >&2; exit $rc' ERR

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

step() {
  printf '\n=== %s ===\n' "$*"
}

# retry <max-attempts> <command...>  — exponential backoff (2s, 4s, 8s, ...)
retry() {
  local max="${1:?retry: max attempts required}"; shift
  local n=1
  local delay=2
  until "$@"; do
    if (( n >= max )); then
      printf 'retry: gave up after %d attempts: %s\n' "$n" "$*" >&2
      return 1
    fi
    printf 'retry: attempt %d failed; sleeping %ds before retry %d/%d\n' "$n" "$delay" "$((n + 1))" "$max" >&2
    sleep "$delay"
    delay=$((delay * 2))
    n=$((n + 1))
  done
}

# verify <description> <command...>  — post-step assertion
verify() {
  local desc="$1"; shift
  if ! "$@" >/dev/null 2>&1; then
    printf 'verify FAILED: %s\n  command: %s\n' "$desc" "$*" >&2
    return 1
  fi
  printf '  verified: %s\n' "$desc"
}

# apt with lock-timeout (so concurrent apt processes don't fail us)
APT_OPTS=(-o DPkg::Lock::Timeout=120 -o DPkg::Options::=--force-confdef -o DPkg::Options::=--force-confold)

apt_update() { retry 3 apt-get "${APT_OPTS[@]}" update; }
apt_install() { retry 3 apt-get "${APT_OPTS[@]}" install -y "$@"; }
apt_upgrade() { retry 3 apt-get "${APT_OPTS[@]}" upgrade -y; }

# ---------------------------------------------------------------------------
# OS sanity
# ---------------------------------------------------------------------------

step "OS check"
if ! grep -q "Ubuntu 24" /etc/os-release; then
  echo "WARNING: not Ubuntu 24.x. Continuing, but YMMV."
fi
. /etc/os-release
echo "  $PRETTY_NAME ($VERSION_CODENAME)"

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------

step "Time: UTC + NTP"
timedatectl set-timezone UTC
systemctl enable --now systemd-timesyncd
verify "timezone is UTC" bash -c "[[ \$(timedatectl show -p Timezone --value) == 'UTC' ]]"

# ---------------------------------------------------------------------------
# APT baseline
# ---------------------------------------------------------------------------

step "APT update + upgrade + base packages"
export DEBIAN_FRONTEND=noninteractive
apt_update
apt_upgrade
apt_install \
  ca-certificates curl gnupg lsb-release \
  ufw unattended-upgrades \
  htop iotop ncdu \
  pigz pv \
  jq

verify "jq present (needed for daemon.json merge)" command -v jq
verify "ufw present" command -v ufw

# ---------------------------------------------------------------------------
# Unattended security upgrades
# ---------------------------------------------------------------------------

step "Unattended security upgrades"
dpkg-reconfigure -f noninteractive unattended-upgrades

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------

step "Firewall (UFW): SSH + HTTP/S + HTTP/3"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP (Caddy)'
ufw allow 443/tcp comment 'HTTPS (Caddy)'
ufw allow 443/udp comment 'HTTP/3 (Caddy QUIC)'
ufw allow 4433/udp comment 'WebTransport QUIC (EarthLink world stream)'
ufw --force enable
verify "ufw active" bash -c "ufw status | grep -q 'Status: active'"

# ---------------------------------------------------------------------------
# Kernel tuning
# ---------------------------------------------------------------------------

step "Kernel sysctls + per-user fd limits"
cat >/etc/sysctl.d/99-earthlink.conf <<'EOF'
# Redis-friendly memory overcommit
vm.overcommit_memory = 1
# Required for Chroma / Elastic-class workloads (large mmap regions)
vm.max_map_count = 262144
# Raised global file-descriptor cap for many concurrent DB / network FDs
fs.file-max = 2097152
EOF
sysctl --system >/dev/null
verify "vm.overcommit_memory=1" bash -c "[[ \$(sysctl -n vm.overcommit_memory) -eq 1 ]]"
verify "vm.max_map_count=262144" bash -c "[[ \$(sysctl -n vm.max_map_count) -eq 262144 ]]"

cat >/etc/security/limits.d/99-earthlink.conf <<'EOF'
*       soft nofile 65536
*       hard nofile 1048576
root    soft nofile 65536
root    hard nofile 1048576
EOF

# ---------------------------------------------------------------------------
# Swap
# ---------------------------------------------------------------------------

step "Swap (${SWAP_SIZE})"
if [[ ! -f /swapfile ]]; then
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  if ! grep -q '^/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >>/etc/fstab
  fi
fi
verify "swap is active" bash -c "swapon --show | grep -q '/swapfile'"

# ---------------------------------------------------------------------------
# Admin user (interactive: SSH key, sudoer, docker group)
# ---------------------------------------------------------------------------

step "Admin user: $ADMIN_USER"
if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$ADMIN_USER"
fi
usermod -aG sudo "$ADMIN_USER"
verify "$ADMIN_USER in sudo group" bash -c "id -nG '$ADMIN_USER' | tr ' ' '\n' | grep -qx sudo"

if [[ -n "$ADMIN_PUBKEY" ]]; then
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  AUTH_KEYS="/home/$ADMIN_USER/.ssh/authorized_keys"
  touch "$AUTH_KEYS"
  if ! grep -qF "$ADMIN_PUBKEY" "$AUTH_KEYS"; then
    echo "$ADMIN_PUBKEY" >> "$AUTH_KEYS"
  fi
  chown "$ADMIN_USER:$ADMIN_USER" "$AUTH_KEYS"
  chmod 600 "$AUTH_KEYS"
  verify "$ADMIN_USER authorized_keys present" test -s "$AUTH_KEYS"
fi

# ---------------------------------------------------------------------------
# Service user (no shell, no SSH, owns stack files)
# ---------------------------------------------------------------------------

step "Service user: $SERVICE_USER"
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  useradd -m -s /usr/sbin/nologin "$SERVICE_USER"
fi
verify "$SERVICE_USER has nologin shell" bash -c "[[ \$(getent passwd '$SERVICE_USER' | cut -d: -f7) == '/usr/sbin/nologin' ]]"

# ---------------------------------------------------------------------------
# Docker Engine + compose plugin (Docker apt repo, NOT distro)
# ---------------------------------------------------------------------------

step "Docker Engine + compose plugin"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  retry 3 bash -c '
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
  '
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $VERSION_CODENAME stable" \
    >/etc/apt/sources.list.d/docker.list

  apt_update
  apt_install \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
fi
verify "docker installed" command -v docker
verify "docker compose plugin installed" docker compose version

# ---------------------------------------------------------------------------
# Docker daemon: log size + rotation (idempotent jq merge — preserves other keys)
# ---------------------------------------------------------------------------

step "Docker daemon.json (log driver + rotation)"
mkdir -p /etc/docker
DESIRED_DAEMON='{"log-driver":"local","log-opts":{"max-size":"20m","max-file":"5"}}'

if [[ -f /etc/docker/daemon.json && -s /etc/docker/daemon.json ]]; then
  # Merge: existing keys preserved, our keys take precedence on conflict.
  TMP="$(mktemp)"
  jq -s '.[0] * .[1]' /etc/docker/daemon.json <(echo "$DESIRED_DAEMON") > "$TMP"
  if ! cmp -s "$TMP" /etc/docker/daemon.json; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$TMP" /etc/docker/daemon.json
    DAEMON_CHANGED=1
  else
    rm -f "$TMP"
    DAEMON_CHANGED=0
  fi
else
  echo "$DESIRED_DAEMON" | jq . > /etc/docker/daemon.json
  DAEMON_CHANGED=1
fi

systemctl enable --now docker
if [[ "${DAEMON_CHANGED:-0}" == 1 ]]; then
  echo "  daemon.json changed — restarting docker"
  systemctl restart docker
fi
verify "docker daemon active" systemctl is-active --quiet docker

# ---------------------------------------------------------------------------
# Group memberships for docker (after docker is installed so the group exists)
# ---------------------------------------------------------------------------

step "Add $ADMIN_USER + $SERVICE_USER to docker group"
usermod -aG docker "$ADMIN_USER"
usermod -aG docker "$SERVICE_USER"
verify "$ADMIN_USER in docker group"   bash -c "id -nG '$ADMIN_USER'   | tr ' ' '\n' | grep -qx docker"
verify "$SERVICE_USER in docker group" bash -c "id -nG '$SERVICE_USER' | tr ' ' '\n' | grep -qx docker"

# ---------------------------------------------------------------------------
# Dedicated docker bridge network
# ---------------------------------------------------------------------------

step "Docker bridge network: $DOCKER_NETWORK"
if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
  docker network create --driver bridge "$DOCKER_NETWORK" >/dev/null
fi
verify "$DOCKER_NETWORK network exists" docker network inspect "$DOCKER_NETWORK"

# ---------------------------------------------------------------------------
# Final verify pass
# ---------------------------------------------------------------------------

step "Final verification"
verify "docker info responsive"      docker info
verify "swap active"                 bash -c "swapon --show | grep -q '/swapfile'"
verify "ufw active"                  bash -c "ufw status | grep -q 'Status: active'"
verify "$ADMIN_USER exists"          id -u "$ADMIN_USER"
verify "$SERVICE_USER exists"        id -u "$SERVICE_USER"
verify "$DOCKER_NETWORK exists"      docker network inspect "$DOCKER_NETWORK"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

cat <<EOF

==================================================
Bootstrap complete.
Log: $LOG_FILE

Users provisioned:
  - $ADMIN_USER   (interactive admin: sudo + docker, SSH key auth)
  - $SERVICE_USER (service runtime: no shell, no SSH, docker group only)

Next:
  1. From your laptop, SSH as the admin user (key auth):
       ssh $ADMIN_USER@<this-host>

  2. Drop into the service user for stack ops when needed:
       sudo -iu $SERVICE_USER

  3. Place runtime files in /home/$SERVICE_USER/ (as root or sudo):
       - docker-compose.prod.yml
       - .env             (chmod 600, chown $SERVICE_USER:$SERVICE_USER)
       - Caddyfile
       - certs/origin.pem
       - certs/origin.key (chmod 600, chown $SERVICE_USER:$SERVICE_USER)

  4. Authenticate with GHCR (as $SERVICE_USER, so systemd inherits creds):
       sudo -iu $SERVICE_USER docker login ghcr.io

  5. Install + enable systemd unit (as root/sudo):
       cp deploy/earthlink-stack.service /etc/systemd/system/
       systemctl daemon-reload
       systemctl enable --now earthlink-stack.service

SSH lockdown is DEFERRED. Once you've confirmed key auth as
$ADMIN_USER works, run from elevated session:
  sudo deploy/ssh-lockdown.sh
==================================================
EOF
