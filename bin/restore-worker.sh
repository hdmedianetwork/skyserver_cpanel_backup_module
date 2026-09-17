#!/bin/bash
# Root-only restore queue processor. The cPanel end-user plugin never runs
# a restore itself (end users have no permission to) — it just drops a
# request file into /var/spool/skyserver-backup/restore-requests/. This
# script, run every minute from cron as root, picks those requests up,
# verifies ownership, and performs the actual restore.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/s3-lib.sh"

QUEUE_DIR="/var/spool/skyserver-backup/restore-requests"
STATUS_DIR="/var/spool/skyserver-backup/restore-status"
mkdir -p "$QUEUE_DIR" "$STATUS_DIR"

shopt -s nullglob
for REQ in "$QUEUE_DIR"/*.json; do
  ID="$(basename "$REQ" .json)"
  USER="$(jq -r .user "$REQ")"
  TYPE="$(jq -r .type "$REQ")"
  DATE="$(jq -r .date "$REQ")"
  STATUS_FILE="$STATUS_DIR/${ID}.json"

  echo "{\"status\":\"running\"}" > "$STATUS_FILE"

  # Ownership check: the request must name a real cPanel account.
  if ! whmapi1 listaccts --output=jsonpretty | grep -qP "\"user\"\s*:\s*\"${USER}\""; then
    echo "{\"status\":\"failed\",\"error\":\"unknown user\"}" > "$STATUS_FILE"
    rm -f "$REQ"
    continue
  fi

  WORKDIR="$(mktemp -d "/root/skyrestore-${USER}-XXXXXX")"

  if [ "$TYPE" = "full" ]; then
    if s3_download "backups/${USER}/${DATE}/full-account.tar.gz" "$WORKDIR/cpmove-${USER}.tar.gz" \
       && /scripts/restorepkg "$WORKDIR/cpmove-${USER}.tar.gz" >"$WORKDIR/restore.log" 2>&1; then
      echo "{\"status\":\"success\"}" > "$STATUS_FILE"
    else
      echo "{\"status\":\"failed\",\"error\":\"full account restore failed\"}" > "$STATUS_FILE"
    fi

  elif [ "$TYPE" = "database" ]; then
    DB="$(jq -r .db "$REQ")"
    # cPanel databases are always prefixed with the owning username —
    # reject anything that doesn't belong to this user.
    case "$DB" in
      "${USER}_"*) ;;
      *)
        echo "{\"status\":\"failed\",\"error\":\"database does not belong to user\"}" > "$STATUS_FILE"
        rm -rf "$WORKDIR" "$REQ"
        continue
        ;;
    esac
    if s3_download "backups/${USER}/${DATE}/databases/${DB}.sql.gz" "$WORKDIR/${DB}.sql.gz" \
       && gunzip -c "$WORKDIR/${DB}.sql.gz" | mysql "$DB"; then
      echo "{\"status\":\"success\"}" > "$STATUS_FILE"
    else
      echo "{\"status\":\"failed\",\"error\":\"database restore failed\"}" > "$STATUS_FILE"
    fi

  else
    echo "{\"status\":\"failed\",\"error\":\"unknown request type\"}" > "$STATUS_FILE"
  fi

  rm -rf "$WORKDIR"
  rm -f "$REQ"
done
