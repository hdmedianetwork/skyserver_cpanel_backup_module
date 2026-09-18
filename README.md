# SkyServer cPanel Backup Module

Daily, automatic cPanel account + database backups to Amazon S3, with a
self-service restore UI inside every user's cPanel dashboard and a
WHM admin dashboard for the server owner.

## Install

There are two installers. Use **standalone** unless you're developing
against a public clone of this repo — this repo is private, so a plain
`git clone` on a customer's server won't work without handing out
credentials.

### Standalone installer (recommended — for distributing to any server)

`install.sh` at the repo root needs `git clone` access to this repo, which
means it only works for people who have credentials to it. To hand this
module to yourself on a live server, or to other people/clients, build
the **self-contained** installer instead — every module file is embedded
in one `.sh` file (base64), so it needs zero GitHub access at install
time:

```bash
scripts/build-installer.sh
```

This produces `dist/install-standalone.sh`. Upload that one file to the
web server you control — for this project that's
`https://backup.gosecureserver.in/install.sh` — and then on any WHM/root
shell:

```bash
curl -sSL https://backup.gosecureserver.in/install.sh | bash
```

Before trusting that URL in a `| bash` pipeline, confirm the web server
serves the script as plain text rather than executing or rewriting it:

```bash
curl -sSL https://backup.gosecureserver.in/install.sh | head -5
```

You should see the `#!/bin/bash` shebang and the comment header. If you
see HTML, an error page, or nothing, fix the hosting before installing.

Rebuild and re-upload it after every change to `bin/`, `etc/`, `plugin/`
or `whm-plugin/` — it's a build artifact, not something you hand-edit.
Anyone you give the URL to gets the exact same install, with no repo
access needed on their end.

### Git-based installer (for local development only)

```bash
curl -sSL https://raw.githubusercontent.com/hdmedianetwork/skyserver_cpanel_backup_module/main/install.sh | bash
```

Only works if the machine running it can `git clone` this repo (i.e. it's
public, or you've set up credentials on that box) — the standalone
installer above avoids that entirely.

### What either installer does

1. Installs dependencies (`jq`, `awscli`, plus `git` for the git-based one).
2. Places the module in `/opt/skyserver-backup-module`.
3. Creates `/etc/skyserver-backup.conf` from the example (you must edit it
   with your S3 bucket and AWS keys).
4. Installs `/etc/cron.d/skyserver-backup`:
   - `backup-all.sh` daily at 02:00 — backs up every account and applies
     retention.
   - `restore-worker.sh` every minute — processes restore requests queued
     by users (near-instant, cheap no-op when the queue is empty).
5. Adds a **SkyServer Backup Manager** entry to every cPanel theme, under
   the Files section, for every end user.
6. Registers a **SkyServer Backup Manager** WHM plugin (via AppConfig) for
   the admin, under WHM → Plugins.

After install, either edit the config file or use the WHM dashboard's
config form, then do a manual test run:

```bash
nano /etc/skyserver-backup.conf
/opt/skyserver-backup-module/bin/backup-all.sh
```

## Admin dashboard (WHM)

**WHM → Plugins → SkyServer Backup Manager** (`whm-plugin/index.cgi`).
Everything below is doable from the GUI — no SSH needed for day-to-day work:

- Accounts table — every cPanel account, last backup date/size, database
  count, total backups, plus a **Back Up Now** button per account.
- Last run summary — success/fail counts, start/finish time, which
  accounts failed — and **Run Backup Now** for all accounts.
- **Restore an Account** — pick account → backup date → full account or a
  single database. Runs with `source=admin`, so it works even while user
  self-restore is off. This is how you test a restore on a throwaway
  account before exposing the feature to customers.
- Recent restore jobs — who requested what, status, and any error.
- **Test S3 Connection** — verifies the saved bucket and credentials
  before the first nightly run depends on them.
- **Check for Updates / Install Update** — compares this server's VERSION
  against GitHub and, on one click, pulls the latest code and re-runs
  `bin/deploy.sh`. No re-running the installer.
- Backup log viewer — the last 120 lines of
  `/var/log/skyserver-backup.log`, so failures can be diagnosed without
  SSH.
- S3 & retention config form — bucket, region, retention, alert email,
  staging directory, disk safety margin, user-restore toggle, and AWS key
  rotation.

## User dashboard (cPanel)

Inside cPanel → Files → **SkyServer Backup Manager** (`plugin/index.live.php`):

- Stat cards: total backups, last backup date/size, database count.
- **Download** per account backup — the worker hands back a one-hour
  presigned S3 link, so the user never gets S3 credentials. Downloads are
  read-only and stay available even while restore is switched off.
- One-click **Restore** per account backup or per database (when enabled),
  with a confirmation prompt.
- Live status badge (queued → running → success/failed) that polls
  `status.live.php` every few seconds — no page reload needed.

## Updating

Push a change to `main`, bump `VERSION`, and on each server press
**Check for Updates → Install Update** in WHM. That runs
`bin/self-update.sh apply`, which pulls the latest code and re-runs
`bin/deploy.sh` (the same deploy step the installer uses, so there is only
one copy of that logic). Config, spool state and S3 backups are untouched.

If you distribute via the standalone bundle instead, rebuild it with
`scripts/build-installer.sh` and re-upload — but note that servers
installed from the bundle can still self-update from GitHub, since
`self-update.sh` clones fresh when there's no git checkout.

## How it works

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

## Safety features

- **Disk space guard** — an account is skipped (with a clear log line) if
  backing it up would leave less than `DISK_SAFETY_MARGIN_MB` free in
  `BACKUP_WORK_DIR`. Filling the disk takes every site on the server down,
  not just the backup, so this check runs before `pkgacct` does.
- **Backup verification** — every tarball is tested with `tar -tzf` and
  every database dump with `gzip -t` *before* upload. A corrupt backup is
  never uploaded, because a backup that looks fine but won't extract is
  worse than no backup at all.
- **Self-service restore is off by default** — `ENABLE_USER_RESTORE=0`
  hides the restore buttons from users. Enforced in three places: the UI
  hides the buttons, `action.live.php` rejects crafted POSTs, and
  `restore-worker.sh` re-checks before touching live data. Turn it on from
  the WHM dashboard only after you've verified a restore yourself.
- **Failure alerts** — set `ALERT_EMAIL` and a run with any failed account
  emails you the failed account list plus the last 40 log lines. Without
  this, a backup system can fail silently for months.
- **Log rotation** — `/etc/logrotate.d/skyserver-backup` keeps
  `/var/log/skyserver-backup.log` from growing without bound.

## Rolling this out safely

If you don't have a staging server, go in this order rather than enabling
everything at once:

1. Install. Self-service restore stays off — users can see their backups
   but can't restore.
2. Run `bin/backup-user.sh <one-small-account>` by hand and read the output.
3. Download that tarball from S3 and actually open it (`tar -tzf`) —
   confirm it contains real data.
4. Run `bin/backup-all.sh` once by hand, then let cron run for a few
   nights, checking the WHM dashboard each morning.
5. Create a *throwaway* cPanel account, and restore into that to prove the
   restore path works end to end.
6. Only then set self-service restore to Enabled in the WHM dashboard.

## Troubleshooting

**Nightly backups do nothing, and every restore says "unknown user"**

Fixed in 0.7.1. cron runs its jobs with a bare `PATH`
(`/sbin:/bin:/usr/sbin:/usr/bin`), which contains none of cPanel's own
binaries — `whmapi1` lives in `/usr/local/cpanel/bin`. Neither script said so:

- `backup-all.sh` died at its first command substitution, so the log held a
  `Backup run started` line and nothing else, and the dashboard reported
  "Last run finished with no failures".
- `restore-worker.sh` could not verify the account, recorded every request as
  `unknown user`, and then **deleted it** — losing the customer's request.

Meanwhile the same jobs worked fine from the WHM panel, because cpsrvd's
environment does have those paths. Upgrade:

```bash
/opt/skyserver-backup-module/bin/self-update.sh apply
```

`bin/s3-lib.sh` now puts cPanel's directories on the path itself, the cron
file carries an explicit `PATH=` line, and both scripts check their tools up
front and abort with the reason in the log instead of in silence. A restore
is only discarded when the account genuinely does not exist — if WHM cannot
be reached, the request stays queued for the next run.

To confirm it on the server:

```bash
grep '^PATH=' /etc/cron.d/skyserver-backup
/opt/skyserver-backup-module/bin/backup-all.sh          # should list accounts
tail -n 40 /var/log/skyserver-backup.log
```

**A restore fails with "unknown user" for an account that plainly exists**

Fixed in 0.8.1. `whmapi1` exits 0 even when the API call itself failed — the
error lives in `metadata.result` and `metadata.reason`, so an error payload
parses exactly like an empty account list. The worker grepped the raw JSON
for the username, could not tell those two apart, and reported a transient
WHM failure to the customer as "unknown user" — then deleted the request,
which was the only record of what they had asked for. Because it depends on
whether WHM answers cleanly at that moment, it was intermittent: a download
would work and a restore a minute later would not.

The check now reads `metadata.result` and parses the account list with `jq`,
and has three answers instead of two: the account exists, it does not, or it
could not be determined. Only the middle one discards the request; the third
leaves it queued, tells the customer the server could not be reached, and
writes the real reason to `/var/log/skyserver-backup.log` (visible in the
WHM dashboard's Activity Log).

The same release gives the worker an `flock`. cron starts it every minute and
a full-account restore runs for far longer than that, so the next tick used
to pick the same request up again and run a second `/scripts/restorepkg`
over the same account while the first was still going.

**The nightly run stops on one account and never moves on**

Fixed in 0.8.3, in three parts.

A single account that hangs used to stall the whole run, and because the run
holds a lock, every following night was skipped as well. Each account now
gets `ACCOUNT_TIMEOUT_MIN` minutes (default 90, settable in the WHM
dashboard) before the run gives up on it, logs why, and moves to the next.

The lock itself was leaking. `exec 200>lock` hands that descriptor to every
child, so `pkgacct` — and anything it left behind — inherited it. One
orphaned process was then enough to make every later run exit with "another
backup run is already in progress", permanently. Children are now started
with it closed.

And the live-progress watcher added in 0.8.0 was measuring with `du -sk` over
the staging directory every three seconds. On a large account that is a full
tree walk against the same disk `pkgacct` is reading — a progress bar that
had become a second workload. It now starts at fifteen seconds and backs off
to whatever the measurement itself turns out to cost, and writes a line to
the log every five minutes so a long account can be told from a stopped one.

A run that is killed outright — the OOM killer, a reboot — now writes
`Backup run interrupted` on its way out, instead of leaving a `started` line
that reads exactly like a run still in progress.

**A restore fails with "full account restore failed"**

Fixed in 0.8.2 — or rather, that message was. It covered two completely
different failures (a backup that could not be fetched from S3, and a restore
cPanel refused) and threw away the reason for both: `/scripts/restorepkg`
wrote its output into the work directory, which was deleted moments later.

The two halves are now reported separately, each with the real error:

    could not fetch your backup from storage — fatal error: An error occurred
    (AccessDenied) when calling the GetObject operation: Access Denied

    restore failed — The account alivemar already exists.

The full output goes to `/var/log/skyserver-backup.log` (visible in the WHM
dashboard's Activity Log) and a copy is kept at
`/var/spool/skyserver-backup/restore-logs/<request-id>.log`, root-only, and
pruned after 30 days.

`/scripts/restorepkg` is also now called with `--force`. It is built for
restoring an account that is gone and refuses when the account is still
there, which is the opposite of what this feature does — put a backup back
over a live account, after the customer confirms exactly that in a dialog
that spells it out. A cPanel build that does not take the flag falls back to
calling it without, rather than failing on the flag itself.

**A bucket name with a dot in it**

`my.bucket` cannot be reached with virtual-host addressing — the bucket
becomes a subdomain and a wildcard certificate matches one label only, so
every upload fails its TLS handshake. Path style is selected automatically
for such a bucket now, on real Amazon S3 as well as on a custom endpoint.

**The WHM dashboard lists an account's backups, but the account's own
Backup Manager page says "No backups yet"**

The end-user plugin runs as the cPanel account, not as root, so it has to be
able to traverse down to `/var/spool/skyserver-backup/manifests/`. Versions
before 0.5.1 left that spool directory `0750 root:root`, which no account
could enter — so every account saw an empty page while the backups
themselves ran perfectly. Upgrade, which also repairs the existing
manifests:

```bash
/opt/skyserver-backup-module/bin/self-update.sh apply
```

Then check the modes — the directories are traversable but not listable, so
no account can enumerate another's:

```bash
ls -ld /var/spool/skyserver-backup /var/spool/skyserver-backup/manifests
#   drwxr-x--x root root   (0751)
ls -l /var/spool/skyserver-backup/manifests/
#   -rw-r----- root <user>  (0640, one file per account)
```

A single account can be re-published without waiting for the nightly run:

```bash
/opt/skyserver-backup-module/bin/publish-manifest.sh <user>
```

The page now tells the two cases apart: an account with no backups yet still
reads "No backups yet", while an account whose manifest can't be read says so
explicitly instead of pretending there is nothing there.

**`mysqldump: Got error: 1045: "Access denied for user 'root'@'localhost'
(using password: NO)"`**

The MySQL client never saw root's password. It lives in `/root/.my.cnf` on a
cPanel server, which the client only reads when `$HOME` is `/root` — and it
isn't when a backup is launched from the WHM dashboard's CGI, or from a shell
where `HOME` points elsewhere. The scripts now pass that file explicitly
(`--defaults-extra-file`), so upgrade to this version first:

```bash
/opt/skyserver-backup-module/bin/self-update.sh apply
```

If it still fails, the file itself is the problem. Check it:

```bash
ls -l /root/.my.cnf
mysql --defaults-extra-file=/root/.my.cnf -e 'SELECT 1'
```

Missing or rejected, recreate it (`chmod 600`, owned by root):

```ini
[client]
user=root
password="<root mysql password>"
```

or reset the password in WHM » SQL Services » MySQL Root Password, which
rewrites the file for you. Keeping the credentials elsewhere is fine — point
`MYSQL_DEFAULTS_FILE` in `/etc/skyserver-backup.conf` at that file instead.

## Security notes

- Use an IAM user/policy scoped to only this bucket
  (`s3:PutObject`, `GetObject`, `ListBucket`, `DeleteObject` on
  `arn:aws:s3:::<bucket>/*`) — never reuse root AWS credentials.
- `/etc/skyserver-backup.conf` is `chmod 600`, root-only.
- Restore requests are validated against the live WHM account list and
  cPanel's `<user>_<dbname>` naming convention before anything runs.
- Test a real restore on a throwaway account before relying on this in
  production — a mistaken `restorepkg` overwrites the account's current
  state and cannot be undone.

## Uninstall

```bash
/opt/skyserver-backup-module/scripts/uninstall.sh
```

Leaves the config file and existing S3 backups in place.
