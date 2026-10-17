#!/bin/bash
# Deletes S3 backup objects older than RETENTION_DAYS (set in
# /etc/skyserver-backup.conf) to keep storage cost under control, and drops
# the same days from every account's manifest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/s3-lib.sh"

CUTOFF_EPOCH="$(date -d "-${RETENTION_DAYS} days" +%s)"
echo "[*] Applying retention policy: keep last ${RETENTION_DAYS} days"

s3_list "backups/" | while read -r _DATE_STR _TIME_STR _SIZE KEY; do
  [ -z "$KEY" ] && continue
  FOLDER_DATE="$(echo "$KEY" | grep -oP '(?<=backups/)[^/]+/\K\d{4}-\d{2}-\d{2}' || true)"
  [ -z "$FOLDER_DATE" ] && continue
  FOLDER_EPOCH="$(date -d "$FOLDER_DATE" +%s 2>/dev/null || echo 0)"
  if [ "$FOLDER_EPOCH" -ne 0 ] && [ "$FOLDER_EPOCH" -lt "$CUTOFF_EPOCH" ]; then
    echo "  [-] Deleting expired: $KEY"
    # One object that will not delete must not stop the rest from expiring.
    s3_rm "$KEY" || echo "  [!] Could not delete $KEY — it will be retried next run"
  fi
done

# The same days come out of every account's manifest, so the dashboard and
# the restore lists stop offering what was just deleted.
"$SCRIPT_DIR/prune-manifests.sh"
