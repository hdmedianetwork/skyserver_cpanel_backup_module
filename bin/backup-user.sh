#!/bin/bash
# Backs up a single cPanel account (full account via pkgacct + one dump per
# database) and uploads everything to S3. Also writes/updates a per-user
# manifest under /var/spool/skyserver-backup/manifests/<user>.json so the
# cPanel end-user plugin can list backups without ever touching S3
# credentials directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/s3-lib.sh"

USER="${1:?usage: backup-user.sh <cpanel_username>}"
DATE="$(date +%F)"
MANIFEST_DIR="/var/spool/skyserver-backup/manifests"
WORKDIR="$(mktemp -d "/root/skybackup-${USER}-XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$MANIFEST_DIR"

echo "[*] Backing up account: $USER"

# 1. Full account backup via cPanel's native pkgacct (home dir, mail, DNS,
#    config, databases — everything cPanel itself would restore).
/scripts/pkgacct "$USER" "$WORKDIR" >/dev/null

ACCT_TARBALL="$(find "$WORKDIR" -maxdepth 1 -name "cpmove-${USER}*.tar.gz" | head -n1)"
if [ -z "$ACCT_TARBALL" ]; then
  echo "[!] pkgacct produced no tarball for $USER" >&2
  exit 1
fi

s3_upload "$ACCT_TARBALL" "backups/${USER}/${DATE}/full-account.tar.gz"
FULL_SIZE="$(du -h "$ACCT_TARBALL" | cut -f1)"

# 2. Separate per-database dumps, for granular restores that don't require
#    rolling back the whole account.
DB_LIST=()
while IFS= read -r DB; do
  [ -z "$DB" ] && continue
  DB_LIST+=("$DB")
  DUMP="$WORKDIR/${DB}.sql.gz"
  mysqldump --single-transaction --quick "$DB" | gzip > "$DUMP"
  s3_upload "$DUMP" "backups/${USER}/${DATE}/databases/${DB}.sql.gz"
done < <(uapi --user="$USER" Mysql list_databases 2>/dev/null | grep -oP '(?<=database: )\S+' || true)

# 3. Update the per-user manifest that the cPanel plugin reads.
MANIFEST_FILE="$MANIFEST_DIR/${USER}.json"
DB_JSON="$(printf '%s\n' "${DB_LIST[@]:-}" | jq -R 'select(length > 0)' | jq -s .)"
ENTRY="$(jq -n --arg date "$DATE" --arg size "$FULL_SIZE" --argjson dbs "$DB_JSON" \
  '{date: $date, full_size: $size, databases: $dbs}')"

if [ -f "$MANIFEST_FILE" ]; then
  jq --argjson entry "$ENTRY" \
    '([.[] | select(.date != $entry.date)] + [$entry]) | sort_by(.date) | reverse' \
    "$MANIFEST_FILE" > "$MANIFEST_FILE.tmp" && mv "$MANIFEST_FILE.tmp" "$MANIFEST_FILE"
else
  echo "[$ENTRY]" | jq '.' > "$MANIFEST_FILE"
fi
chmod 640 "$MANIFEST_FILE"
chown "root:${USER}" "$MANIFEST_FILE" 2>/dev/null || true

echo "[*] Done: $USER"
