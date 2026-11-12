#!/bin/bash
# Moves the backups of an account that no longer exists on this server out
# of backups/<user>/ and into terminated/<user>/<stamp>/, and keeps a record
# of them, so that:
#
#   * the nightly retention does not expire them a week after termination —
#     a terminated account never gets a new backup, so under the ordinary
#     rule its last one is gone after RETENTION_DAYS;
#   * a new account created later under the same username starts with an
#     empty backups/<user>/ and its owner never sees, downloads or restores
#     the previous customer's data;
#   * the WHM panel can list them under "Terminated" and recreate the
#     account from any of them (bin/restore-worker.sh, type "recreate").
#
#   archive-terminated.sh --user <name>   archive one account (the post-
#                                         termination hook calls this)
#   archive-terminated.sh --scan          archive every account that has
#                                         backups but is not on this server
#                                         (nightly, from retention-cleanup.sh)
#
# Either way an account is only archived once WHM has confirmed it is gone:
# an account list that could not be fetched archives nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/s3-lib.sh"

SPOOL_DIR="/var/spool/skyserver-backup"
TERMINATED_DIR="$SPOOL_DIR/terminated"
MANIFEST_DIR="$SPOOL_DIR/manifests"
LOCK_FILE="$SPOOL_DIR/archive-terminated.lock"

MODE=""
ONE_USER=""
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --scan)  MODE="scan" ;;
    --user)  MODE="user"; ONE_USER="${2:-}"; shift ;;
    --force) FORCE=1 ;;
    *) echo "usage: archive-terminated.sh --scan | --user <name> [--force]" >&2; exit 64 ;;
  esac
  shift
done
[ -n "$MODE" ] || { echo "usage: archive-terminated.sh --scan | --user <name>" >&2; exit 64; }

case "$ONE_USER" in
  *[!a-zA-Z0-9_]*) echo "[!] archive-terminated: not a cPanel username: $ONE_USER" >&2; exit 64 ;;
esac

sky_require_tools whmapi1 jq aws || exit 1

mkdir -p "$TERMINATED_DIR"
# Root only: these records name every customer who ever left, and what
# their backups contained.
chmod 700 "$TERMINATED_DIR" 2>/dev/null || true

# One at a time. The hook and the nightly scan can both reach the same
# account, and two moves of one prefix would split it across two stamps.
exec 202>"$LOCK_FILE"
if ! flock -w 600 202; then
  echo "[!] archive-terminated: another archive is still running — leaving it to that one." >&2
  exit 0
fi

# The accounts that exist, one per line — or exit 2 when WHM could not say.
# whmapi1 exits 0 even when the call failed, and an error payload parses
# exactly like an empty list, which here would read as "every account was
# terminated". So the reply's own result flag is checked, and an empty list
# is refused as well.
live_accounts() {
  local out
  out="$(whmapi1 listaccts --output=jsonpretty 2>&1)" || { printf '%s\n' "$out" >&2; return 2; }
  if [ "$(printf '%s' "$out" | jq -r '.metadata.result // empty' 2>/dev/null)" != "1" ]; then
    echo "[!] whmapi1 listaccts did not succeed: $(printf '%s' "$out" | jq -r '.metadata.reason // "unparseable reply"' 2>/dev/null)" >&2
    return 2
  fi
  printf '%s' "$out" | jq -r '.data.acct[]?.user' 2>/dev/null
}

if ! ACCOUNTS="$(live_accounts)"; then
  echo "[!] archive-terminated: could not get the account list from WHM — nothing archived." >&2
  exit 1
fi
if [ -z "$ACCOUNTS" ]; then
  echo "[!] archive-terminated: WHM listed no accounts at all — refusing to treat every account as terminated." >&2
  exit 1
fi

is_live() { printf '%s\n' "$ACCOUNTS" | grep -qxF "$1"; }

# A record still marked "archiving" is a move that was interrupted. Its stamp
# is reused, so the rest of the objects land next to the ones already moved.
pending_stamp() { # <user>
  local f
  for f in "$TERMINATED_DIR/${1}--"*.json; do
    [ -f "$f" ] || continue
    if [ "$(jq -r '.status // ""' "$f" 2>/dev/null)" = "archiving" ]; then
      jq -r '.stamp' "$f"
      return 0
    fi
  done
  return 1
}

# What is actually stored under one archive, as manifest entries:
# [{date, full_size_bytes, databases: [..]}, ...], newest first.
archived_entries() { # <user> <stamp>
  local prefix="terminated/${1}/${2}/"
  s3_list "$prefix" 2>/dev/null | awk '{print $3, $4}' | jq -R -s --arg p "$prefix" '
    [ split("\n")[] | select(length > 0) | capture("^(?<size>[0-9]+) (?<key>.+)$")
      | .rel = (.key | ltrimstr($p))
      | select(.rel | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}/")) ]
    | group_by(.rel[0:10])
    | map({
        date: .[0].rel[0:10],
        full_size_bytes: ([ .[] | select(.rel | endswith("/full-account.tar.gz")) | (.size | tonumber) ] | add // 0),
        has_full: any(.[]; .rel | endswith("/full-account.tar.gz")),
        databases: [ .[] | select(.rel | test("/databases/[^/]+\\.sql\\.gz$"))
                         | .rel | capture("/databases/(?<d>[^/]+)\\.sql\\.gz$").d ]
      })
    | sort_by(.date) | reverse'
}

archive_one() { # <user>
  local user="$1" stamp record manifest meta entries count

  if is_live "$user"; then
    echo "  [=] $user is an account on this server — not archived."
    return 0
  fi

  stamp="$(pending_stamp "$user" || true)"
  [ -n "$stamp" ] || stamp="$(date -u +%Y%m%dT%H%M%S)"
  record="$TERMINATED_DIR/${user}--${stamp}.json"

  # What the account looked like: the manifest we kept for it, and what the
  # pre-termination hook saved about it (domain, owner, plan) when it ran.
  manifest='[]'
  if [ -r "$MANIFEST_DIR/${user}.json" ]; then
    manifest="$(jq -c 'if type == "array" then . else [] end' "$MANIFEST_DIR/${user}.json" 2>/dev/null || echo '[]')"
  fi
  meta='{}'
  if [ -r "$TERMINATED_DIR/pending-${user}.json" ]; then
    meta="$(jq -c '.' "$TERMINATED_DIR/pending-${user}.json" 2>/dev/null || echo '{}')"
  fi

  # Written before anything moves, so an interruption leaves a record that
  # says where the objects were going.
  if [ ! -f "$record" ]; then
    jq -n --arg user "$user" --arg stamp "$stamp" --arg ts "$(date -Iseconds)" \
          --argjson meta "$meta" --argjson manifest "$manifest" \
      '{user: $user, stamp: $stamp, status: "archiving", terminated_at: ($meta.terminated_at // $ts),
        archived_at: null, domain: ($meta.domain // null), owner: ($meta.owner // null),
        plan: ($meta.plan // null), detected_by: (if $meta.user then "hook" else "scan" end),
        manifest: $manifest, backups: []}' > "$record.tmp"
    mv "$record.tmp" "$record"
    chmod 600 "$record"
  fi

  echo "  [>] $user: moving backups/$user/ to terminated/$user/$stamp/"
  if ! aws_s3 s3 mv "s3://${S3_BUCKET}/backups/${user}/" \
         "s3://${S3_BUCKET}/terminated/${user}/${stamp}/" --recursive --only-show-errors; then
    echo "  [!] $user: the move did not finish — it is picked up again on the next run." >&2
    return 1
  fi

  entries="$(archived_entries "$user" "$stamp")"
  [ -n "$entries" ] || entries='[]'
  count="$(printf '%s' "$entries" | jq '[.[] | select(.has_full)] | length')"

  # The sizes and failed-database notes from the manifest are kept where the
  # day is still there; the bucket decides which days that is.
  jq --argjson entries "$entries" --arg ts "$(date -Iseconds)" '
      .manifest as $m
      | .backups = [ $entries[] | select(.has_full) | del(.has_full) as $e
                     | ($m | map(select(.date == $e.date)) | .[0] // {}) as $old
                     | $e + { full_size: ($old.full_size // null) }
                     + (if $old.failed_databases then {failed_databases: $old.failed_databases} else {} end) ]
      | .status = (if (.backups | length) > 0 then "archived" else "empty" end)
      | .archived_at = $ts
      | del(.manifest)' "$record" > "$record.tmp"
  mv "$record.tmp" "$record"
  chmod 600 "$record"

  # The account is gone, and a new one with this name must not inherit its
  # list of backups.
  rm -f "$MANIFEST_DIR/${user}.json" "$TERMINATED_DIR/pending-${user}.json"
  sky_progress_clear "$user"

  if [ "$count" -gt 0 ]; then
    echo "  [+] $user: $count backup(s) archived as terminated/$user/$stamp/"
  else
    rm -f "$record"
    echo "  [-] $user: nothing restorable was stored — no archive kept."
  fi
}

FAILED=0
if [ "$MODE" = "user" ]; then
  [ -n "$ONE_USER" ] || { echo "usage: archive-terminated.sh --user <name>" >&2; exit 64; }
  archive_one "$ONE_USER" || FAILED=1
  exit "$FAILED"
fi

# --scan: every username with a backups/<user>/ prefix in the bucket, plus
# any manifest left behind for one with no prefix (nothing to move, but the
# stale manifest still has to go so a new account cannot inherit it).
echo "[*] Looking for backups of accounts that are no longer on this server..."
if ! PREFIXES="$(aws_s3 s3 ls "s3://${S3_BUCKET}/backups/" 2>&1)"; then
  echo "[!] Could not list s3://${S3_BUCKET}/backups/: $PREFIXES" >&2
  exit 1
fi
PREFIX_USERS="$(printf '%s\n' "$PREFIXES" | awk '$1 == "PRE" { sub("/$", "", $2); print $2 }' \
                | grep -E '^[a-zA-Z0-9_]+$' || true)"

ORPHANS=()
while IFS= read -r u; do
  [ -n "$u" ] || continue
  is_live "$u" || ORPHANS+=("$u")
done <<< "$PREFIX_USERS"

# A move that was interrupted after its last object left backups/ has no
# prefix to find it by, but its record still says "archiving".
for f in "$TERMINATED_DIR"/*--*.json; do
  [ -f "$f" ] || continue
  [ "$(jq -r '.status // ""' "$f" 2>/dev/null)" = "archiving" ] || continue
  u="$(jq -r '.user // ""' "$f" 2>/dev/null)"
  case "$u" in ''|*[!a-zA-Z0-9_]*) continue ;; esac
  printf '%s\n' ${ORPHANS[@]+"${ORPHANS[@]}"} | grep -qxF "$u" || ORPHANS+=("$u")
done

# A cap on how much one scan may decide is gone. A WHM that answers with a
# partial list would otherwise move most of the bucket in one night. Real
# terminations come through the hook one at a time; anything bigger is for
# a person to confirm with --force.
TOTAL_PREFIXES="$(printf '%s\n' "$PREFIX_USERS" | grep -c . || true)"
LIMIT=$(( TOTAL_PREFIXES / 2 ))
[ "$LIMIT" -ge 5 ] || LIMIT=5
if [ "${#ORPHANS[@]}" -gt "$LIMIT" ] && [ "$FORCE" != "1" ]; then
  echo "[!] ${#ORPHANS[@]} of $TOTAL_PREFIXES accounts with backups are not on this server." >&2
  echo "[!] That is more than one scan archives on its own. If they really were all" >&2
  echo "[!] terminated, run: $SCRIPT_DIR/archive-terminated.sh --scan --force" >&2
  exit 1
fi

for u in ${ORPHANS[@]+"${ORPHANS[@]}"}; do
  archive_one "$u" || FAILED=1
done

for f in "$MANIFEST_DIR"/*.json; do
  [ -f "$f" ] || continue
  u="$(basename "$f" .json)"
  is_live "$u" && continue
  printf '%s\n' "$PREFIX_USERS" | grep -qxF "$u" && continue
  rm -f "$f"
  echo "  [-] $u: dropped the manifest of an account that is gone and has nothing in the bucket"
done

[ "${#ORPHANS[@]}" -gt 0 ] || echo "  [=] none found."
exit "$FAILED"
