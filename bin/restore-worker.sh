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

write_status() { # <id> <user> <status> [error]
  jq -n --arg id "$1" --arg user "$2" --arg status "$3" --arg error "${4:-}" --arg ts "$(date -Iseconds)" \
    '{id: $id, user: $user, status: $status, updated_at: $ts} + (if $error != "" then {error: $error} else {} end)' \
    > "$STATUS_DIR/${1}.json"
}

# The plugin runs as the cPanel user and can't read the root-only config,
# so publish ENABLE_USER_RESTORE as a world-readable marker it can stat.
if [ "$ENABLE_USER_RESTORE" = "1" ]; then
  : > "$USER_RESTORE_MARKER"
  chmod 644 "$USER_RESTORE_MARKER"
else
  rm -f "$USER_RESTORE_MARKER"
fi

shopt -s nullglob
for REQ in "$QUEUE_DIR"/*.json; do
  ID="$(basename "$REQ" .json)"
  USER="$(jq -r .user "$REQ")"
  TYPE="$(jq -r .type "$REQ")"
  DATE="$(jq -r .date "$REQ")"

  write_status "$ID" "$USER" "running"

  # Re-check here rather than trusting the plugin's own check: this is the
  # only place that actually touches live data.
  if [ "$ENABLE_USER_RESTORE" != "1" ]; then
    write_status "$ID" "$USER" "failed" "self-service restore is disabled by the server administrator"
    rm -f "$REQ"
    continue
  fi

  # Ownership check: the request must name a real cPanel account.
  if ! whmapi1 listaccts --output=jsonpretty | grep -qP "\"user\"\s*:\s*\"${USER}\""; then
    write_status "$ID" "$USER" "failed" "unknown user"
    rm -f "$REQ"
    continue
  fi

  WORKDIR="$(mktemp -d "/root/skyrestore-${USER}-XXXXXX")"

  if [ "$TYPE" = "full" ]; then
    if s3_download "backups/${USER}/${DATE}/full-account.tar.gz" "$WORKDIR/cpmove-${USER}.tar.gz" \
       && /scripts/restorepkg "$WORKDIR/cpmove-${USER}.tar.gz" >"$WORKDIR/restore.log" 2>&1; then
      write_status "$ID" "$USER" "success"
    else
      write_status "$ID" "$USER" "failed" "full account restore failed"
    fi

  elif [ "$TYPE" = "database" ]; then
    DB="$(jq -r .db "$REQ")"
    # cPanel databases are always prefixed with the owning username —
    # reject anything that doesn't belong to this user.
    case "$DB" in
      "${USER}_"*) ;;
      *)
        write_status "$ID" "$USER" "failed" "database does not belong to user"
        rm -rf "$WORKDIR" "$REQ"
        continue
        ;;
    esac
    if s3_download "backups/${USER}/${DATE}/databases/${DB}.sql.gz" "$WORKDIR/${DB}.sql.gz" \
       && gunzip -c "$WORKDIR/${DB}.sql.gz" | mysql "$DB"; then
      write_status "$ID" "$USER" "success"
    else
      write_status "$ID" "$USER" "failed" "database restore failed"
    fi

  else
    write_status "$ID" "$USER" "failed" "unknown request type"
  fi

  rm -rf "$WORKDIR"
  rm -f "$REQ"
done
