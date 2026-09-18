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
LOCK_FILE="/var/spool/skyserver-backup/restore-worker.lock"
LOG="/var/log/skyserver-backup.log"
mkdir -p "$QUEUE_DIR" "$STATUS_DIR"

# cron starts this every minute, and a full-account restore runs for far
# longer than that. Without a lock the next tick picks up the same request —
# it is only removed once the restore finishes — and runs a second
# /scripts/restorepkg over the same account while the first is still going.
exec 201>"$LOCK_FILE"
if ! flock -n 201; then
  exit 0   # the previous run is still working; nothing to do
fi

log() { echo "[restore] $*" >> "$LOG"; }

# The work directory is removed as soon as the job ends, and it took the only
# record of what went wrong with it. Keep a copy for the administrator, and
# put its tail in the backup log so it shows up in the WHM Activity Log
# without anyone having to go looking for a file.
keep_log() { # <id> <logfile> <what>
  local id="$1" src="$2" what="$3" dir="/var/spool/skyserver-backup/restore-logs"
  log "request $id failed while $what:"
  if [ -r "$src" ]; then
    sed -e 's/^/    /' "$src" | tail -n 25 >> "$LOG" || true
    mkdir -p "$dir" 2>/dev/null || return 0
    chmod 700 "$dir" 2>/dev/null || true
    cp "$src" "$dir/${id}.log" 2>/dev/null || true
    chmod 600 "$dir/${id}.log" 2>/dev/null || true
    log "full output kept at $dir/${id}.log"
  else
    log "    (the command produced no output)"
  fi
}

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

# Same file, but carrying where the job has got to. A restore can run for a
# long time, and "running" on its own tells the customer nothing about
# whether it is moving.
write_running() { # <id> <user> <step> <of> <message> [percent] [detail]
  jq -n --arg id "$1" --arg user "$2" --arg step "$3" --arg of "$4" \
        --arg msg "$5" --arg pct "${6:-}" --arg detail "${7:-}" --arg ts "$(date -Iseconds)" \
    '{id: $id, user: $user, status: "running", updated_at: $ts,
      step: ($step|tonumber), steps: ($of|tonumber), message: $msg}
     + (if $pct    != "" then {percent: ($pct|tonumber)} else {} end)
     + (if $detail != "" then {detail: $detail} else {} end)' \
    > "$STATUS_DIR/${1}.json"
  own_status "$1" "$2"
}

# /scripts/restorepkg is built for restoring an account that is gone, and
# refuses when the account is still there. Putting a backup back over a live
# account is exactly what this feature does — and what the customer confirmed
# in a dialog that spelled it out — so it is asked for explicitly. Older
# cPanel builds that do not take the flag fall back rather than failing on
# the flag itself.
run_restorepkg() { # <tarball> <logfile>
  if /scripts/restorepkg --force "$1" >"$2" 2>&1; then
    return 0
  fi
  if grep -qaiE 'unknown option|invalid option|unrecognized option|usage:' "$2"; then
    /scripts/restorepkg "$1" >"$2" 2>&1
    return $?
  fi
  return 1
}

# Is this a real account on this server?
#
#   0  yes
#   1  no such account
#   2  could not be determined — prints why on stdout
#
# The third answer is the point. whmapi1 exits 0 even when the API call
# itself failed: the error lives in metadata.result, and an error payload
# parses exactly like an empty account list. Grepping the raw JSON for the
# username could not tell those apart, so a transient WHM failure was
# reported to the customer as "unknown user" and their request was deleted.
account_exists() { # <user>
  local user="$1" out result
  if ! out="$(whmapi1 listaccts --output=jsonpretty 2>&1)"; then
    printf '%s' "$out" | tr '\n' ' '
    return 2
  fi

  result="$(printf '%s' "$out" | jq -r '.metadata.result // empty' 2>/dev/null || true)"
  if [ "$result" != "1" ]; then
    printf '%s' "$out" | jq -r '.metadata.reason // "whmapi1 returned an unparseable reply"' 2>/dev/null \
      || printf 'whmapi1 returned an unparseable reply'
    return 2
  fi

  if printf '%s' "$out" | jq -e --arg u "$user" '[.data.acct[]?.user] | index($u) != null' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Pulls an object down while reporting how far along it is, by watching the
# local file grow against the size the bucket reports. Falls back to a plain
# transfer when the size cannot be determined.
fetch_with_progress() { # <id> <user> <s3_key> <dest> <step> <of> <message>
  local id="$1" user="$2" key="$3" dest="$4" step="$5" of="$6" msg="$7"
  local total have pct

  total="$(s3_object_size "$key")"
  [ -n "$total" ] || total=0

  # Kept so the caller can say what went wrong. Without this the AWS CLI's
  # error goes to cron's mailbox and the customer gets "restore failed".
  s3_download "$key" "$dest" >"${dest}.err" 2>&1 &
  local dl_pid=$!

  while kill -0 "$dl_pid" 2>/dev/null; do
    have="$(stat -c %s "$dest" 2>/dev/null || echo 0)"
    pct=""
    if [ "$total" -gt 0 ]; then
      pct=$(( have * 100 / total ))
      if [ "$pct" -gt 99 ]; then pct=99; fi
    fi
    write_running "$id" "$user" "$step" "$of" "$msg" "$pct" \
      "$(numfmt --to=iec --suffix=B "$have" 2>/dev/null || echo "$have bytes")"
    sleep 3
  done
  wait "$dl_pid"
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

# Kept output is for diagnosing a failure that just happened, not forever.
find /var/spool/skyserver-backup/restore-logs -type f -name '*.log' -mtime +30 \
  -delete 2>/dev/null || true

shopt -s nullglob
for REQ in "$QUEUE_DIR"/*.json; do
  ID="$(basename "$REQ" .json)"
  USER="$(jq -r .user "$REQ")"
  TYPE="$(jq -r .type "$REQ")"
  DATE="$(jq -r .date "$REQ")"
  SOURCE="$(jq -r '.source // "user"' "$REQ")"

  # A request that cannot be read is a broken request, not a missing
  # account, and saying so is the difference between a fixable report and a
  # baffling one.
  case "$USER" in
    ''|null) USER="" ;;
    *[!a-zA-Z0-9_]*) USER="" ;;
  esac
  if [ -z "$USER" ]; then
    write_status "$ID" "unknown" "failed" "this request could not be read — please try again"
    log "request $ID has no usable user field — dropping it"
    rm -f "$REQ"
    continue
  fi

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

  # Ownership check. "WHM could not tell us" and "that account does not
  # exist" are different things, and treating the first as the second is
  # destructive: the request is the only record of what the customer asked
  # for, so a server-side hiccup must never be what deletes it.
  set +e
  ACCT_WHY="$(account_exists "$USER")"
  ACCT_RC=$?
  set -e

  if [ "$ACCT_RC" = "2" ]; then
    write_status "$ID" "$USER" "failed" "could not verify your account with the server — retrying"
    log "could not verify $USER for request $ID: $ACCT_WHY"
    continue   # $REQ stays in the queue for the next run
  fi

  if [ "$ACCT_RC" != "0" ]; then
    write_status "$ID" "$USER" "failed" "unknown user"
    log "request $ID names $USER, which WHM does not list as an account — dropping it"
    rm -f "$REQ"
    continue
  fi

  # A download hands back a time-limited S3 link rather than touching the
  # account, so the user never needs S3 credentials of their own.
  if [ "$TYPE" = "download" ]; then
    write_running "$ID" "$USER" 1 2 "Locating your backup" "" "$DATE"
    write_running "$ID" "$USER" 2 2 "Creating a private download link" "" "valid for one hour"
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
    TARBALL="$WORKDIR/cpmove-${USER}.tar.gz"
    RLOG="$WORKDIR/restore.log"

    # Split into its two halves. "full account restore failed" covered both
    # a backup that could not be fetched and a restore that cPanel refused,
    # and threw away the reason for either.
    if ! fetch_with_progress "$ID" "$USER" "backups/${USER}/${DATE}/full-account.tar.gz" \
           "$TARBALL" 1 2 "Fetching your backup from storage"; then
      write_status "$ID" "$USER" "failed" \
        "could not fetch your backup from storage — $(sky_failure_reason "${TARBALL}.err")"
      keep_log "$ID" "${TARBALL}.err" "fetching the backup for $USER"

    elif write_running "$ID" "$USER" 2 2 "Restoring your account" "" "files, email, DNS and databases" \
         && run_restorepkg "$TARBALL" "$RLOG"; then
      write_status "$ID" "$USER" "success"

    else
      write_status "$ID" "$USER" "failed" "restore failed — $(sky_failure_reason "$RLOG")"
      keep_log "$ID" "$RLOG" "restoring $USER"
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
    DUMP="$WORKDIR/${DB}.sql.gz"
    ILOG="$WORKDIR/import.log"

    if ! fetch_with_progress "$ID" "$USER" "backups/${USER}/${DATE}/databases/${DB}.sql.gz" \
           "$DUMP" 1 2 "Fetching the database backup"; then
      write_status "$ID" "$USER" "failed" \
        "could not fetch the database backup — $(sky_failure_reason "${DUMP}.err")"
      keep_log "$ID" "${DUMP}.err" "fetching $DB for $USER"

    elif write_running "$ID" "$USER" 2 2 "Importing the database" "" "$DB" \
         && gunzip -c "$DUMP" 2>"$ILOG" | mysql_cmd mysql "$DB" >>"$ILOG" 2>&1; then
      write_status "$ID" "$USER" "success"

    else
      write_status "$ID" "$USER" "failed" "could not import $DB — $(sky_failure_reason "$ILOG")"
      keep_log "$ID" "$ILOG" "importing $DB for $USER"
    fi

  else
    write_status "$ID" "$USER" "failed" "unknown request type"
  fi

  rm -rf "$WORKDIR"
  rm -f "$REQ"
done
