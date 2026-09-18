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

mkdir -p "$MANIFEST_DIR" "$BACKUP_WORK_DIR"
# The end-user plugin runs as the cPanel account and has to be able to
# traverse down to its own manifest. deploy.sh sets these modes too; doing
# it here as well keeps a spool directory created by hand — or by an older
# version of this module — from silently hiding every backup from the
# account it belongs to. 0751 is traversal without a listing, so no account
# can enumerate another's manifests.
chmod 751 "$(dirname "$MANIFEST_DIR")" "$MANIFEST_DIR" 2>/dev/null || true

echo "[*] Backing up account: $USER"

# This runs per account from backup-all.sh, which has already checked, but
# also straight from the WHM panel's per-account button — so check here too
# rather than failing on a bare "command not found" halfway through.
sky_require_tools jq aws || exit 1
if [ ! -x /scripts/pkgacct ]; then
  echo "[!] /scripts/pkgacct is missing or not executable — cPanel cannot package this account." >&2
  exit 1
fi

# pkgacct dumps this account's databases too, so a broken MySQL login means
# a silently incomplete tarball, not just missing .sql.gz files. Prove the
# credentials work before doing any work at all.
mysql_check_access || exit 1

# Refuse to start unless the staging area can hold this account. Filling
# the disk would take every site on this server down, not just the backup.
HOME_DIR="$(getent passwd "$USER" 2>/dev/null | cut -d: -f6 || true)"
if [ -z "$HOME_DIR" ] || [ ! -d "$HOME_DIR" ]; then
  HOME_DIR="/home/$USER"
fi
ACCT_KB="$(du -sk "$HOME_DIR" 2>/dev/null | awk '{print $1}')"
[ -n "$ACCT_KB" ] || ACCT_KB=0
NEEDED_KB=$(( ACCT_KB + DISK_SAFETY_MARGIN_MB * 1024 ))

STAGE_DIR="$(sky_pick_work_dir "$NEEDED_KB" || true)"
if [ -z "$STAGE_DIR" ]; then
  echo "[!] Not enough space to package $USER: need $(( NEEDED_KB / 1024 ))MB" \
       "(account $(( ACCT_KB / 1024 ))MB + $(( DISK_SAFETY_MARGIN_MB ))MB margin)." >&2
  echo "[!] Checked:" >&2
  sky_work_dir_report >&2
  echo "[!] Point BACKUP_WORK_DIR in $SKYSERVER_CONF at a filesystem with room," >&2
  echo "[!] or lower DISK_SAFETY_MARGIN_MB if the margin is what is out of reach." >&2
  exit 1
fi
if [ "$STAGE_DIR" != "$BACKUP_WORK_DIR" ]; then
  echo "[*] $BACKUP_WORK_DIR cannot hold $USER ($(( NEEDED_KB / 1024 ))MB needed) —" \
       "staging in $STAGE_DIR instead."
fi

WORKDIR="$(mktemp -d "$STAGE_DIR/skybackup-${USER}-XXXXXX")"
# The progress file goes with the work directory: whether this run succeeds,
# fails or is killed, the account's page must not be left showing a backup
# that is no longer happening.
cleanup() {
  # backup-all.sh gives each account a time limit, so this has to hold for a
  # run that is cut short as well as one that ends normally — otherwise
  # pkgacct is left running on a disk nobody is waiting for any more, and
  # the customer's page keeps showing a backup that stopped.
  if [ -n "${PKG_PID:-}" ]; then kill "$PKG_PID" 2>/dev/null || true; fi
  rm -rf "$WORKDIR"
  sky_progress_clear "$USER"
}
trap cleanup EXIT
trap 'exit 143' INT TERM

TOTAL_STEPS=4

# 1. Full account backup via cPanel's native pkgacct (home dir, mail, DNS,
#    config, databases — everything cPanel itself would restore).
#
# This is the long step, so it runs in the background and the staging
# directory is watched growing against the size of the account itself. That
# is an estimate — pkgacct compresses as it goes — but it is a real number
# moving in real time, which is the difference between a customer waiting
# and a customer wondering whether anything is happening at all.
sky_progress "$USER" 1 "$TOTAL_STEPS" "Packaging your account" 0 \
  "files, email, DNS and settings"

/scripts/pkgacct "$USER" "$WORKDIR" >/dev/null &
PKG_PID=$!

# Measuring must never cost a meaningful fraction of what it measures. `du`
# walks the whole staging tree, and on a large account that is seconds of
# disk time — against the same disk pkgacct is reading. Polled every three
# seconds it stopped being a progress bar and became a second workload.
# Start at fifteen seconds and back off to whatever the measurement itself
# turns out to cost.
POLL=15
NEXT_BEAT=$SECONDS
while kill -0 "$PKG_PID" 2>/dev/null; do
  BEFORE=$SECONDS
  USED_KB="$(du -sk "$WORKDIR" 2>/dev/null | awk '{print $1}')"
  COST=$(( SECONDS - BEFORE ))
  if [ -z "$USED_KB" ]; then USED_KB=0; fi

  PCT=0
  if [ "$ACCT_KB" -gt 0 ]; then PCT=$(( USED_KB * 100 / ACCT_KB )); fi
  if [ "$PCT" -gt 99 ]; then PCT=99; fi
  sky_progress "$USER" 1 "$TOTAL_STEPS" "Packaging your account" "$PCT" \
    "files, email, DNS and settings"

  # An account big enough to make du slow is an account where a coarse
  # progress bar is fine, and where the disk time matters most.
  if [ "$COST" -ge 2 ]; then
    POLL=$(( COST * 20 ))
    if [ "$POLL" -gt 300 ]; then POLL=300; fi
  fi

  # A line in the log every few minutes, so an account that is genuinely
  # taking hours can be told apart from one that has stopped.
  if [ "$SECONDS" -ge "$NEXT_BEAT" ]; then
    echo "[*] still packaging $USER — ${PCT}% after $(( SECONDS / 60 ))m"
    NEXT_BEAT=$(( SECONDS + 300 ))
  fi

  sleep "$POLL"
done
wait "$PKG_PID"   # its exit status is this script's, as it was before

ACCT_TARBALL="$(find "$WORKDIR" -maxdepth 1 -name "cpmove-${USER}*.tar.gz" | head -n1)"
if [ -z "$ACCT_TARBALL" ]; then
  echo "[!] pkgacct produced no tarball for $USER" >&2
  exit 1
fi

sky_progress "$USER" 2 "$TOTAL_STEPS" "Checking the archive" "" \
  "making sure it can be restored"

# A tarball that uploads cleanly but won't extract is worse than no backup
# at all, because it looks like protection. Prove it's readable first.
if ! tar -tzf "$ACCT_TARBALL" >/dev/null 2>&1; then
  echo "[!] Backup tarball for $USER failed its integrity check — not uploading" >&2
  exit 1
fi

FULL_BYTES="$(stat -c %s "$ACCT_TARBALL")"
FULL_SIZE="$(du -h "$ACCT_TARBALL" | cut -f1)"

sky_progress "$USER" 3 "$TOTAL_STEPS" "Uploading to secure storage" "" "$FULL_SIZE"
s3_upload "$ACCT_TARBALL" "backups/${USER}/${DATE}/full-account.tar.gz"

# 2. Separate per-database dumps, for granular restores that don't require
#    rolling back the whole account.

# The account's databases, one per line, from cPanel's view and MySQL's own.
# Neither alone is enough: uapi needs cPanel's tooling reachable and the
# account to have the MySQL feature, while the prefix query only knows the
# <user>_<name> convention. A database missed here is one nobody notices is
# unprotected, so take both and let the caller dedupe.
list_databases() { # <cpanel_user>
  local user="${1//[^a-zA-Z0-9]/}"
  local uapi_bin out err status

  uapi_bin="$(command -v uapi || true)"
  [ -n "$uapi_bin" ] || uapi_bin="/usr/local/cpanel/bin/uapi"

  if [ -x "$uapi_bin" ]; then
    err="$(mktemp)"
    # stderr is kept out of $out: cPanel logs warnings there, and folding one
    # into the JSON would leave jq nothing it can parse.
    if out="$("$uapi_bin" --user="$user" --output=jsonpretty Mysql list_databases 2>"$err")"; then
      status="$(printf '%s' "$out" | jq -r '.result.status // 0' 2>/dev/null)"
      if [ "$status" = "1" ]; then
        printf '%s' "$out" | jq -r '.result.data[]?.database // empty' 2>/dev/null
      else
        # A suspended account answers exactly like this: status 0, no data.
        echo "[!] uapi listed no databases for $user (using MySQL's list instead):" \
             "$(printf '%s' "$out" | jq -r '(.result.errors // ["unknown error"]) | join("; ")' 2>/dev/null | tr '\n' ' ')" >&2
      fi
    else
      echo "[!] uapi failed for $user (using MySQL's list instead): $(tr '\n' ' ' < "$err")" >&2
    fi
    rm -f "$err"
  else
    echo "[!] uapi not found — using MySQL's own database list for $user" >&2
  fi

  # cPanel usernames cannot contain an underscore, so this prefix matches
  # this account's databases and nobody else's.
  mysql_cmd mysql --batch --skip-column-names \
    -e "SHOW DATABASES LIKE '${user}\\_%'" 2>/dev/null || true
}

# Collected before the loop so progress can say "2 of 5" rather than
# counting up towards a total nobody knows.
ALL_DBS=()
while IFS= read -r DB; do
  if [ -n "$DB" ]; then ALL_DBS+=("$DB"); fi
done < <(list_databases "$USER" | sort -u)

# One dump, reported rather than fatal. mysqldump's own exit status is what
# matters, not the pipeline's — gzip succeeds happily on a truncated stream.
dump_database() { # <db> <dest.gz> <errfile>
  local rc
  set +e
  mysql_cmd mysqldump --single-transaction --quick "$1" 2>"$3" | gzip > "$2"
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] || return 1
  gzip -t "$2" 2>/dev/null || return 1
  return 0
}

DB_TOTAL="${#ALL_DBS[@]}"
DB_LIST=()
DB_FAILED=()
DB_REASONS=()
DB_N=0
for DB in ${ALL_DBS[@]+"${ALL_DBS[@]}"}; do
  DB_N=$(( DB_N + 1 ))
  sky_progress "$USER" 4 "$TOTAL_STEPS" "Backing up databases" \
    "$(( (DB_N - 1) * 100 / DB_TOTAL ))" "$DB ($DB_N of $DB_TOTAL)"

  DUMP="$WORKDIR/${DB}.sql.gz"
  DB_ERR="$WORKDIR/${DB}.err"

  if ! dump_database "$DB" "$DUMP" "$DB_ERR"; then
    # "Table is marked as crashed" is a MyISAM table wanting REPAIR, and it
    # is the one dump failure with a standard remedy. Applying it writes to
    # a customer's data, so it is the administrator's decision — but when
    # they have made it, one crashed table should not cost a database.
    if [ "$MYSQL_AUTO_REPAIR" = "1" ] && grep -qai 'marked as crashed' "$DB_ERR"; then
      echo "[*] $DB has a crashed table — repairing and trying again."
      mysql_cmd mysqlcheck --auto-repair --quick "$DB" >>"$DB_ERR" 2>&1 || true
      dump_database "$DB" "$DUMP" "$DB_ERR" || true
    fi
  fi

  if [ -s "$DUMP" ] && gzip -t "$DUMP" 2>/dev/null && [ ! -s "$DB_ERR" ]; then
    DB_LIST+=("$DB")
    s3_upload "$DUMP" "backups/${USER}/${DATE}/databases/${DB}.sql.gz"
  else
    # The rest of the account is still worth keeping. Losing an entire
    # account's backup over one broken table is the worst possible trade,
    # and it is what used to happen: set -e killed the script here, before
    # the manifest recording the tarball already in S3 was ever written.
    REASON="$(sky_failure_reason "$DB_ERR")"
    if grep -qai 'marked as crashed' "$DB_ERR"; then
      REASON="$REASON — run: mysqlcheck --auto-repair $DB"
    fi
    DB_FAILED+=("$DB")
    DB_REASONS+=("$REASON")
    echo "[!] Database $DB could not be backed up: $REASON" >&2
    rm -f "$DUMP"
  fi
done

if [ "${#DB_LIST[@]}" -eq 0 ] && [ "${#DB_FAILED[@]}" -eq 0 ]; then
  echo "[*] No databases found for $USER — the account tarball is still a full backup."
fi

# 3. Update the per-user manifest that the cPanel plugin reads.
MANIFEST_FILE="$MANIFEST_DIR/${USER}.json"
DB_JSON="$(printf '%s\n' "${DB_LIST[@]:-}" | jq -R 'select(length > 0)' | jq -s .)"

# Databases that could not be dumped are named in the manifest, so neither
# the customer's page nor the dashboard shows a backup as complete when a
# piece of it is missing.
FAILED_JSON='[]'
if [ "${#DB_FAILED[@]}" -gt 0 ]; then
  for _i in "${!DB_FAILED[@]}"; do
    FAILED_JSON="$(jq -c --argjson a "$FAILED_JSON" --arg n "${DB_FAILED[$_i]}" \
                     --arg r "${DB_REASONS[$_i]:-}" -n '$a + [{name:$n, reason:$r}]')"
  done
fi

ENTRY="$(jq -n --arg date "$DATE" --arg size "$FULL_SIZE" --argjson bytes "$FULL_BYTES" \
  --argjson dbs "$DB_JSON" --argjson failed "$FAILED_JSON" \
  '{date: $date, full_size: $size, full_size_bytes: $bytes, databases: $dbs}
   + (if ($failed | length) > 0 then {failed_databases: $failed} else {} end)')"

if [ -f "$MANIFEST_FILE" ]; then
  jq --argjson entry "$ENTRY" \
    '([.[] | select(.date != $entry.date)] + [$entry]) | sort_by(.date) | reverse' \
    "$MANIFEST_FILE" > "$MANIFEST_FILE.tmp" && mv "$MANIFEST_FILE.tmp" "$MANIFEST_FILE"
else
  echo "[$ENTRY]" | jq '.' > "$MANIFEST_FILE"
fi
# Hand the manifest to the account it describes, so its Backup Manager
# page can actually list what was just uploaded.
"$SCRIPT_DIR/publish-manifest.sh" "$USER"

if [ "${#DB_FAILED[@]}" -gt 0 ]; then
  echo "[*] Done: $USER ($FULL_SIZE, ${#DB_LIST[@]} databases) —" \
       "${#DB_FAILED[@]} database(s) could not be backed up: ${DB_FAILED[*]}"
  echo "[!] ${#DB_FAILED[@]} of $DB_TOTAL databases failed: ${DB_REASONS[0]}" >&2
  # 2 is "the account is backed up, but not everything in it" — the run
  # records it as a partial rather than as a success or a total failure.
  exit 2
fi

echo "[*] Done: $USER ($FULL_SIZE, ${#DB_LIST[@]} databases)"
