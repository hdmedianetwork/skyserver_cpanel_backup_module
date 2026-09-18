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

# pkgacct dumps this account's databases too, so a broken MySQL login means
# a silently incomplete tarball, not just missing .sql.gz files. Prove the
# credentials work before doing any work at all.
mysql_check_access || exit 1

# Refuse to start unless the staging area can hold this account. Filling
# the disk would take every site on this server down, not just the backup.
HOME_DIR="$(getent passwd "$USER" | cut -d: -f6)"
if [ -z "$HOME_DIR" ] || [ ! -d "$HOME_DIR" ]; then
  HOME_DIR="/home/$USER"
fi
ACCT_KB="$(du -sk "$HOME_DIR" 2>/dev/null | awk '{print $1}')"
[ -n "$ACCT_KB" ] || ACCT_KB=0
AVAIL_KB="$(df -Pk "$BACKUP_WORK_DIR" | awk 'NR==2 {print $4}')"
NEEDED_KB=$(( ACCT_KB + DISK_SAFETY_MARGIN_MB * 1024 ))

if [ "$AVAIL_KB" -lt "$NEEDED_KB" ]; then
  echo "[!] Not enough space in $BACKUP_WORK_DIR for $USER:" \
       "need $(( NEEDED_KB / 1024 ))MB (account $(( ACCT_KB / 1024 ))MB + margin)," \
       "have $(( AVAIL_KB / 1024 ))MB free" >&2
  exit 1
fi

WORKDIR="$(mktemp -d "$BACKUP_WORK_DIR/skybackup-${USER}-XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

# 1. Full account backup via cPanel's native pkgacct (home dir, mail, DNS,
#    config, databases — everything cPanel itself would restore).
/scripts/pkgacct "$USER" "$WORKDIR" >/dev/null

ACCT_TARBALL="$(find "$WORKDIR" -maxdepth 1 -name "cpmove-${USER}*.tar.gz" | head -n1)"
if [ -z "$ACCT_TARBALL" ]; then
  echo "[!] pkgacct produced no tarball for $USER" >&2
  exit 1
fi

# A tarball that uploads cleanly but won't extract is worse than no backup
# at all, because it looks like protection. Prove it's readable first.
if ! tar -tzf "$ACCT_TARBALL" >/dev/null 2>&1; then
  echo "[!] Backup tarball for $USER failed its integrity check — not uploading" >&2
  exit 1
fi

FULL_BYTES="$(stat -c %s "$ACCT_TARBALL")"
s3_upload "$ACCT_TARBALL" "backups/${USER}/${DATE}/full-account.tar.gz"
FULL_SIZE="$(du -h "$ACCT_TARBALL" | cut -f1)"

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

DB_LIST=()
while IFS= read -r DB; do
  [ -z "$DB" ] && continue
  DUMP="$WORKDIR/${DB}.sql.gz"
  mysql_cmd mysqldump --single-transaction --quick "$DB" | gzip > "$DUMP"
  if ! gzip -t "$DUMP" 2>/dev/null; then
    echo "[!] Dump of database $DB failed its integrity check — not uploading" >&2
    exit 1
  fi
  DB_LIST+=("$DB")
  s3_upload "$DUMP" "backups/${USER}/${DATE}/databases/${DB}.sql.gz"
done < <(list_databases "$USER" | sort -u)

if [ "${#DB_LIST[@]}" -eq 0 ]; then
  echo "[*] No databases found for $USER — the account tarball is still a full backup."
fi

# 3. Update the per-user manifest that the cPanel plugin reads.
MANIFEST_FILE="$MANIFEST_DIR/${USER}.json"
DB_JSON="$(printf '%s\n' "${DB_LIST[@]:-}" | jq -R 'select(length > 0)' | jq -s .)"
ENTRY="$(jq -n --arg date "$DATE" --arg size "$FULL_SIZE" --argjson bytes "$FULL_BYTES" --argjson dbs "$DB_JSON" \
  '{date: $date, full_size: $size, full_size_bytes: $bytes, databases: $dbs}')"

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

echo "[*] Done: $USER ($FULL_SIZE, ${#DB_LIST[@]} databases)"
