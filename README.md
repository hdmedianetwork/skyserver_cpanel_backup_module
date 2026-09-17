# SkyServer cPanel Backup Module

Daily, automatic cPanel account + database backups to Amazon S3, with a
self-service restore UI inside every user's cPanel dashboard and a
WHM admin dashboard for the server owner.

## Install (on a WHM/root shell)

```bash
curl -sSL https://raw.githubusercontent.com/hdmedianetwork/skyserver_cpanel_backup_module/main/install.sh | bash
```

This:
1. Installs dependencies (`git`, `jq`, `awscli`).
2. Clones this repo into `/opt/skyserver-backup-module`.
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

## Security notes

- Use an IAM user/policy scoped to only this bucket
  (`s3:PutObject`, `GetObject`, `ListBucket`, `DeleteObject` on
  `arn:aws:s3:::<bucket>/*`) — never reuse root AWS credentials.
- `/etc/skyserver-backup.conf` is `chmod 600`, root-only.
- Restore requests are validated against the live WHM account list and
  cPanel's `<user>_<dbname>` naming convention before anything runs.
- Test a real restore on a staging account before relying on this in
  production — a mistaken `restorepkg` overwrites the account's current
  state.

## Uninstall

```bash
/opt/skyserver-backup-module/scripts/uninstall.sh
```

Leaves the config file and existing S3 backups in place.
