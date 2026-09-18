#!/bin/bash
# Makes one account's backup manifest reachable by the account itself.
#
# The cPanel end-user plugin runs as the logged-in account, not as root, so
# a manifest that only root can reach renders exactly like an account that
# has never been backed up. This script is the single place that decides
# who may read a manifest, and it is called both from the nightly backup
# (bin/backup-user.sh) and from bin/deploy.sh, so an update repairs
# accounts backed up before the permissions were right.
set -euo pipefail

USER="${1:?usage: publish-manifest.sh <cpanel_username>}"
SPOOL_DIR="/var/spool/skyserver-backup"
MANIFEST_FILE="$SPOOL_DIR/manifests/${USER}.json"

[ -f "$MANIFEST_FILE" ] || exit 0

# Readable by this account and nobody else. The directories above it are
# 0751 (traversable, not listable), so no account can discover another's.
chmod 640 "$MANIFEST_FILE"
if ! chown "root:${USER}" "$MANIFEST_FILE" 2>/dev/null; then
  echo "[!] Could not give $USER group ownership of $MANIFEST_FILE —" \
       "that account's Backup Manager page will list no backups." >&2
fi

# A second copy inside the account's own home. The plugin prefers the spool
# manifest, but a server with a jailed filesystem may not expose /var/spool
# to the account at all, and this copy is always within reach of the only
# account allowed to see it.
HOME_DIR="$(getent passwd "$USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || exit 0

COPY_DIR="$HOME_DIR/.skyserver-backup"
mkdir -p "$COPY_DIR" 2>/dev/null || exit 0
chown "${USER}:${USER}" "$COPY_DIR" 2>/dev/null || true
chmod 750 "$COPY_DIR" 2>/dev/null || true

if ! install -m 640 -o "$USER" -g "$USER" \
     "$MANIFEST_FILE" "$COPY_DIR/manifest.json" 2>/dev/null; then
  echo "[!] Could not write $COPY_DIR/manifest.json for $USER" >&2
fi
