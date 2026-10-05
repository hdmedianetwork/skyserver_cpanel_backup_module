# Architecture

How the SkyServer Backup Manager is put together, and why it behaves the way it does. For setup
and day-to-day use, see the [README](../README.md).

## Components

```
cron (root, daily)
  └─ bin/backup-all.sh
       ├─ for each account: bin/backup-user.sh <user>
       │     ├─ /scripts/pkgacct <user>         → full account tarball
       │     ├─ mysqldump per database           → per-DB .sql.gz
       │     ├─ upload both to S3 under backups/<user>/<date>/
       │     ├─ write /var/spool/skyserver-backup/manifests/<user>.json
       │     └─ bin/publish-manifest.sh <user>   → hands that manifest to
       │           the account (0640 root:<user>, plus a copy in its home)
       └─ bin/retention-cleanup.sh                → deletes S3 objects
                                                     older than RETENTION_DAYS

cPanel user dashboard
  └─ plugin/index.live.php ("SkyServer Backup Manager")
       ├─ reads the user's own manifest.json (no S3 credentials exposed)
       ├─ user clicks Download/Restore → plugin/action.live.php queues it
       └─ plugin/status.live.php — ?id= polls one request, ?api=state
             re-reads this account's backups; nothing reloads the page

WHM admin dashboard
  └─ whm-plugin/index.cgi ("SkyServer Backup Manager", root only)
       ├─ renders the page shell once, then talks to its own JSON API
       │     (index.cgi?api=state|log|run_now|backup_user|admin_restore|
       │      save_config|test_s3|update_check|update_apply) — nothing reloads
       ├─ reads manifests/, restore-status/ and the log for the overview
       ├─ "Run backup now" → backs up all accounts on demand, followed live
       ├─ queues admin restores into the same drop box the plugin uses
       └─ config form writes /etc/skyserver-backup.conf

cron (root, every minute)
  └─ bin/restore-worker.sh
       ├─ picks up queued requests
       ├─ verifies the request's user/database actually belongs to that account
       ├─ downloads the backup from S3
       └─ runs /scripts/restorepkg (full account) or `mysql` import (single DB)
```

The end-user plugin never gets S3 or root access — it only writes a
request file. The actual restore always runs as root via the cron worker,
after an ownership check. This keeps one customer from ever being able to
restore or read another customer's backup.

The spool directory is shared by every account, so its modes carry that
guarantee:

| Path | Mode | Why |
| --- | --- | --- |
| `/var/spool/skyserver-backup/` | `0751` | accounts traverse it; none can list it |
| `manifests/` | `0751` | same — and each `<user>.json` is `0640 root:<user>` |
| `restore-requests/` | `1733` | a drop box: accounts add their own request (`0600`), the sticky bit stops them touching anyone else's |
| `restore-status/` | `0751` | each status file is `0640 root:<user>`, since it can carry a presigned download URL |

## The panels

Both panels are built from one design system, `ui/sky-ui.php`, which
`bin/deploy.sh` copies next to each of them — so the customer and their host
are looking at the same thing, and the two cannot drift apart. It holds the
stylesheet and a small front-end runtime (`window.SkyUI`): inline SVG icons,
toasts, the modal, the JSON helper, the light/dark switch and the tab strip.
Nothing is fetched from a CDN, so both render identically on a server with no
outbound access.

Each panel fills the width of the page, and hides the row of cPanel's own
logo and links that the chrome prints above plugin content — it is duplicate
furniture above a page that has its own heading. That removal is keyed off
the links themselves rather than a class name, is bounded, and refuses to
touch any block that also contains the panel, so on a layout it does not
recognise it changes nothing.

### Resuming an interrupted run

A run over a couple of hundred accounts takes hours, and a server that goes
down in the middle of one should not mean starting again from the first
account — the work already in S3 is still good.

`backup-all.sh --resume` backs up every account that does not already have a
backup stored under today's date, and skips the ones that do.

That test is the manifest, not the run's own bookkeeping, and deliberately
so: a manifest is written only after the upload succeeded, so it is the one
record that cannot be optimistic. It is still there after a crash that took
the state file with it, after an upgrade from a version that never wrote
one, and after an account was backed up by hand from the dashboard in
between. Accounts that failed have no manifest entry for today, so they are
retried; resuming a day that is already complete does nothing rather than
re-uploading everything.

`/var/spool/skyserver-backup/run-state.json`, rewritten after every account,
is what gives the dashboard the detail — which account it stopped on, which
ones failed and why. When there is no usable state file the dashboard works
the same question out from the manifests, so **Resume (N left)** appears
whenever some accounts have today's backup and some do not. It stays hidden
when *none* do: that is a day that has not started, and the ordinary **Run
full backup** is the honest name for it.

While a run is going the same state drives a live *90 of 187, now on
sharmaho* progress bar.

### When something inside an account fails

Two failures used to cost an account its entire backup, and both are common
enough to hit a server with a couple of hundred accounts on any given night.

**A crashed database table.** `mysqldump` stops with *Table 'x' is marked as
crashed and should be repaired*, and because the dumps run under `set -e`
after the account tarball has already been uploaded, the script died before
writing the manifest — so an account whose backup was sitting in S3 showed as
never backed up. A failed dump is now reported rather than fatal: the
account keeps its backup, the databases that did dump are in it, and the ones
that did not are named in the manifest with the reason. The dashboard shows
that account as **partial**, not as a success and not as a failure, because
it is neither — and retrying it would not fix a crashed table. Set
`MYSQL_AUTO_REPAIR=1` (or pick it in Settings) to have the run repair such a
table and try once more.

**No room to stage the account.** The tarball is built on disk before it is
uploaded, and `/root` on a cPanel server is usually on a small filesystem.
With `BACKUP_WORK_DIR_FALLBACK=1` (the default) the run stages on whichever
local filesystem has room, respecting the disk safety margin wherever it
lands, and says in the log where it went. With it off, the account fails —
but the message now lists every filesystem it checked and how much each had
free.

### Which accounts failed, and why

A name on a failed list is not something anyone can act on. `no space left
on /root` is.

Every run captures each account's own output separately as well as appending
it to the log, and keeps the line that looks like the actual error in
`run-state.json` next to the account it belongs to. The Accounts tab has a
**Last result** column carrying it, a **Show only failed (N)** filter, and a
**Retry** button on each failed row that backs up that one account.

A failure stops counting once the account has a backup from today, so
retrying one by hand clears its own row — the display is derived from what
is actually in S3 rather than from bookkeeping that could be left stale.

### WHM admin dashboard

A single page that never reloads. PHP renders the shell once with a snapshot
of the state embedded in it, and every button after that goes through
`index.cgi?api=<action>`, which answers JSON.

- **Overview** — run state, a health checklist (bucket, credentials,
  accounts with no backup, failures from the last run) and recent restores.
- **Accounts** — every cPanel account with the age of its latest backup,
  filterable, with per-account "Back up" and "Restore".
- **Restores** — queue a restore (account → date → whole account or one
  database, behind a two-step confirmation) and watch the jobs.
- **Settings** — destination, retention, alerting and the customer
  self-restore switch, with a live S3 connection test.
- **Activity Log** — the tail of `/var/log/skyserver-backup.log`, colourised.

While a backup run or a restore is in flight the page polls itself every
five seconds so the tiles, the accounts table and the log stay current; when
nothing is running it makes no requests at all. There is a light and a dark
theme (the button beside "Refresh"), remembered per browser.

Only actions that change something accept POST, so a prefetched or
bookmarked URL can never start a backup or a restore. The AWS keys are never
sent to the browser — the form shows whether credentials are saved and
leaves them alone unless you type new ones.

### cPanel end-user page

The same shell, scoped to one account: tiles for how many backups are kept,
when the last one ran, its size and how many databases it covers, then two
tabs.

- **Account backups** — every stored date with its size and what it covers,
  each with **Download** and, when the server allows it, **Restore**.
- **Databases** — each database in each backup, restorable on its own.

A download or a restore is queued through `action.live.php` and then polled
through `status.live.php` every three seconds. The row shows what the worker
is actually doing — *Fetching your backup from storage, 1 of 2, 42%* — with
a bar that keeps moving even before a percentage is known, so "working"
never reads as "stuck". A finished download starts on its own and leaves the
link clickable in case the browser blocks that. Polling stops as soon as
nothing is in flight.

While the nightly job is backing that account up, the page says so, with the
stage it has reached: packaging, checking the archive, uploading, then each
database in turn. `bin/backup-user.sh` writes that to
`/var/spool/skyserver-backup/progress/<user>.json` (`0640 root:<user>`, like
the manifests) and removes it on the way out however it exits; the page also
ignores a file older than fifteen minutes, so a run killed without its trap
firing cannot leave a customer watching a backup that stopped long ago.

The percentages are real, not animation: packaging is measured by watching
the staging directory grow against the size of the account, and a transfer
by watching the local file grow against the size the bucket reports. A restore asks
for confirmation in a dialog that names the account, the date and exactly
what is about to be overwritten.

The page never holds S3 credentials and never performs a restore itself — it
only drops a request file into the queue that `bin/restore-worker.sh`, running
as root, picks up and re-validates.

## S3 layout

```
s3://<bucket>/backups/<cpanel-user>/<YYYY-MM-DD>/full-account.tar.gz
s3://<bucket>/backups/<cpanel-user>/<YYYY-MM-DD>/databases/<db>.sql.gz
```
