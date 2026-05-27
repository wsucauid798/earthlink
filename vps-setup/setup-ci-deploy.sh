#!/usr/bin/env bash
# One-shot VPS-side setup for CI-driven deploy (D28).
#
# Installs:
#   1. CI public key into wsawyerr's authorized_keys (idempotent)
#   2. /etc/sudoers.d/earthlink-deploy with NOPASSWD scoped to ONE command
#
# Run as root (or via sudo from wsawyerr):
#   sudo bash /tmp/setup-ci-deploy.sh
#
# Pre-conditions: /tmp/id_earthlink_ci.pub and /tmp/earthlink-deploy.sudoers
# have been scp'd into /tmp.

set -Eeuo pipefail

ADMIN_USER="${ADMIN_USER:-wsawyerr}"
SRC="${SRC:-/tmp}"
SUDOERS_DEST="/etc/sudoers.d/earthlink-deploy"
LOG_FILE="${LOG_FILE:-/var/log/earthlink-ci-deploy-setup.log}"

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

printf '\n##############################################################\n'
printf '# CI deploy setup: %s (UTC)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '##############################################################\n\n'

trap 'rc=$?; printf "\nERROR: setup failed at line %d (exit %d): %s\n  see: %s\n" \
  "$LINENO" "$rc" "$BASH_COMMAND" "$LOG_FILE" >&2; exit $rc' ERR

step() { printf '\n=== %s ===\n' "$*"; }
verify() {
  local d="$1"; shift
  if ! "$@" >/dev/null 2>&1; then
    printf 'verify FAILED: %s\n  command: %s\n' "$d" "$*" >&2
    return 1
  fi
  printf '  verified: %s\n' "$d"
}

# --- Preconditions ---------------------------------------------------------

step "Preconditions"
verify "$ADMIN_USER user exists"           id -u "$ADMIN_USER"
verify "CI public key staged"              test -s "$SRC/id_earthlink_ci.pub"
verify "sudoers staged"                    test -s "$SRC/earthlink-deploy.sudoers"

# --- Install CI public key into wsawyerr's authorized_keys ----------------

step "Install CI public key into ~/$ADMIN_USER/.ssh/authorized_keys"

AUTH_DIR="/home/$ADMIN_USER/.ssh"
AUTH_KEYS="$AUTH_DIR/authorized_keys"

install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$AUTH_DIR"
[[ -f "$AUTH_KEYS" ]] || install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" /dev/null "$AUTH_KEYS"

CI_KEY="$(cat "$SRC/id_earthlink_ci.pub")"
if grep -qF "$CI_KEY" "$AUTH_KEYS"; then
  echo "  CI key already present in authorized_keys (idempotent)"
else
  echo "$CI_KEY" >> "$AUTH_KEYS"
  echo "  CI key appended"
fi
chown "$ADMIN_USER:$ADMIN_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

# --- Install scoped NOPASSWD sudoers rule ---------------------------------

step "Install $SUDOERS_DEST"

# visudo -cf validates the file BEFORE we put it in /etc/sudoers.d/
TMP_SUDOERS="$(mktemp)"
cp "$SRC/earthlink-deploy.sudoers" "$TMP_SUDOERS"
chmod 0440 "$TMP_SUDOERS"
chown root:root "$TMP_SUDOERS"

if ! visudo -cf "$TMP_SUDOERS"; then
  rm -f "$TMP_SUDOERS"
  echo "FAILED: sudoers file did not pass visudo validation; not installed" >&2
  exit 1
fi

install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS_DEST"
rm -f "$TMP_SUDOERS"

verify "sudoers file present"              test -f "$SUDOERS_DEST"
verify "sudoers file mode 0440"            bash -c "[[ \$(stat -c %a '$SUDOERS_DEST') -eq 440 ]]"

# --- Smoke test the NOPASSWD grant ----------------------------------------

step "Smoke test: $ADMIN_USER can run the scoped command without password"
if sudo -n -u "$ADMIN_USER" sudo -n /bin/systemctl is-active earthlink-stack >/dev/null 2>&1; then
  echo "  $ADMIN_USER can run scoped systemctl without password"
else
  echo "  WARNING: smoke test could not verify NOPASSWD grant (may still work for restart)"
fi

# --- Cleanup ---------------------------------------------------------------

step "Cleanup staging files"
rm -f "$SRC/id_earthlink_ci.pub" "$SRC/earthlink-deploy.sudoers" "$SRC/setup-ci-deploy.sh"

cat <<EOF

==================================================
CI deploy setup complete.
Log: $LOG_FILE

Next steps (browser, on github.com):

  1. Open: https://github.com/wsucauid798/earthlink-server/settings/secrets/actions
  2. Add three repository secrets:

       VPS_HOST     = 77.68.50.14
       VPS_USER     = $ADMIN_USER
       VPS_SSH_KEY  = (paste full contents of laptop file
                       %USERPROFILE%\\.ssh\\id_earthlink_ci
                       — the PRIVATE key, including the BEGIN/END lines)

  3. Commit + push .github/workflows/publish-and-deploy.yml in
     the earthlink-server repo to trigger the first run.
==================================================
EOF
