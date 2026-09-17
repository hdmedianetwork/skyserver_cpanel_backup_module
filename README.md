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

**WHM → Plugins → SkyServer Backup Manager** (`whm-plugin/index.cgi`):

- Accounts table — every cPanel account, last backup date/size, database
  count, total backup count.
- Last run summary — success/fail counts, start/finish time, which
  accounts failed.
- **Run Backup Now** — triggers `backup-all.sh` in the background on
  demand (disabled while a run is already in progress).
- Recent restore jobs — who requested what, status, and any error.
- S3 & retention config form — edit bucket, region, retention days, and
  (optionally) rotate the AWS keys without touching the shell.

## User dashboard (cPanel)

Inside cPanel → Files → **SkyServer Backup Manager** (`plugin/index.live.php`):

- Stat cards: total backups, last backup date/size, database count.
- One-click **Restore** per account backup or per database, with a
  confirmation prompt.
- Live status badge (queued → running → success/failed) that polls
  `status.live.php` every few seconds — no page reload needed.

## How it works

```
cron (root, daily)
  └─ bin/backup-all.sh
       ├─ for each account: bin/backup-user.sh <user>
       │     ├─ /scripts/pkgacct <user>         → full account tarball
       │     ├─ mysqldump per database           → per-DB .sql.gz
       │     ├─ upload both to S3 under backups/<user>/<date>/
       │     └─ write /var/spool/skyserver-backup/manifests/<user>.json
       └─ bin/retention-cleanup.sh                → deletes S3 objects
                                                     older than RETENTION_DAYS

cPanel user dashboard
  └─ plugin/index.live.php ("SkyServer Backup Manager")
       ├─ reads the user's own manifest.json (no S3 credentials exposed)
       ├─ user clicks Restore → plugin/action.live.php queues the request
       └─ plugin/status.live.php polled by JS until success/failed

WHM admin dashboard
  └─ whm-plugin/index.cgi ("SkyServer Backup Manager", root only)
       ├─ reads manifests/, restore-status/ and the log for the overview
       ├─ "Run Backup Now" → backs up all accounts on demand
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
