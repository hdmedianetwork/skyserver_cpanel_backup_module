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

# The plugin runs as the cPanel account, so it needs to traverse down here
# (0751: traversal, no listing) and to drop a request file into the queue.
# The queue is a drop box — world-writable plus the sticky bit, so an
# account can add its own request but not remove or replace anyone else's.
chmod 751 "$(dirname "$QUEUE_DIR")" "$STATUS_DIR" 2>/dev/null || true
chmod 1733 "$QUEUE_DIR" 2>/dev/null || true

# A status file can carry a presigned download URL, so hand it to the one
# account entitled to it rather than leaving it world-readable.
own_status() { # <id> <user>
  local f="$STATUS_DIR/${1}.json"
  chmod 640 "$f"
  chown "root:${2}" "$f" 2>/dev/null || true
}

write_status() { # <id> <user> <status> [error]
  jq -n --arg id "$1" --arg user "$2" --arg status "$3" --arg error "${4:-}" --arg ts "$(date -Iseconds)" \
    '{id: $id, user: $user, status: $status, updated_at: $ts} + (if $error != "" then {error: $error} else {} end)' \
    > "$STATUS_DIR/${1}.json"
  own_status "$1" "$2"
}

write_download_status() { # <id> <user> <url>
  jq -n --arg id "$1" --arg user "$2" --arg url "$3" --arg ts "$(date -Iseconds)" \
    '{id: $id, user: $user, status: "success", download_url: $url, updated_at: $ts}' \
    > "$STATUS_DIR/${1}.json"
  own_status "$1" "$2"
}

# The plugin runs as the cPanel user and can't read the root-only config,
# so publish ENABLE_USER_RESTORE as a world-readable marker it can stat.
if [ "$ENABLE_USER_RESTORE" = "1" ]; then
  : > "$USER_RESTORE_MARKER"
  chmod 644 "$USER_RESTORE_MARKER"
else
  rm -f "$USER_RESTORE_MARKER"
fi

# Without cPanel's own binaries there is no way to verify who a request
# belongs to, and guessing is how every queued restore ended up recorded as
# "unknown user" and then deleted. Stop before touching the queue: the
# requests stay where they are and are picked up once this is fixed.
if ! sky_require_tools whmapi1 jq aws >&2; then
  echo "[!] restore-worker: cannot run without those commands — the queue is untouched." >&2
  exit 1
fi

shopt -s nullglob
for REQ in "$QUEUE_DIR"/*.json; do
  ID="$(basename "$REQ" .json)"
  USER="$(jq -r .user "$REQ")"
  TYPE="$(jq -r .type "$REQ")"
  DATE="$(jq -r .date "$REQ")"
  SOURCE="$(jq -r '.source // "user"' "$REQ")"

  write_status "$ID" "$USER" "running"

  # Re-check here rather than trusting the plugin's own check: this is the
  # only place that actually touches live data. Downloads only read a
  # backup, and admin-queued requests come from the root-only WHM panel,
  # so neither is subject to the user-facing gate.
  if [ "$TYPE" != "download" ] && [ "$SOURCE" != "admin" ] && [ "$ENABLE_USER_RESTORE" != "1" ]; then
    write_status "$ID" "$USER" "failed" "self-service restore is disabled by the server administrator"
    rm -f "$REQ"
    continue
  fi

  # Ownership check: the request must name a real cPanel account.
  #
  # "WHM would not answer" and "that account does not exist" are different
  # things, and treating the first as the second is destructive: the request
  # is the only record of what the customer asked for, so a server-side
  # hiccup must never be what deletes it.
  if ! ACCTS="$(whmapi1 listaccts --output=jsonpretty 2>&1)"; then
    write_status "$ID" "$USER" "failed" "could not reach WHM to verify the account — retrying"
    echo "[!] whmapi1 listaccts failed while checking $USER: $(printf '%s' "$ACCTS" | tr '\n' ' ')" >&2
    continue   # $REQ stays in the queue for the next run
  fi

  if ! printf '%s' "$ACCTS" | grep -qP "\"user\"\s*:\s*\"${USER}\""; then
    write_status "$ID" "$USER" "failed" "unknown user"
    rm -f "$REQ"
    continue
  fi

  # A download hands back a time-limited S3 link rather than touching the
  # account, so the user never needs S3 credentials of their own.
  if [ "$TYPE" = "download" ]; then
    if URL="$(aws_s3 s3 presign "s3://${S3_BUCKET}/backups/${USER}/${DATE}/full-account.tar.gz" --expires-in 3600 2>/dev/null)"; then
      write_download_status "$ID" "$USER" "$URL"
    else
      write_status "$ID" "$USER" "failed" "could not generate a download link"
    fi
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
       && gunzip -c "$WORKDIR/${DB}.sql.gz" | mysql_cmd mysql "$DB"; then
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
