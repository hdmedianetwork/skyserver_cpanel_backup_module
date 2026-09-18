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

The spool directory is shared by every account, so its modes carry that
guarantee:

| Path | Mode | Why |
| --- | --- | --- |
| `/var/spool/skyserver-backup/` | `0751` | accounts traverse it; none can list it |
| `manifests/` | `0751` | same — and each `<user>.json` is `0640 root:<user>` |
| `restore-requests/` | `1733` | a drop box: accounts add their own request (`0600`), the sticky bit stops them touching anyone else's |
| `restore-status/` | `0751` | each status file is `0640 root:<user>`, since it can carry a presigned download URL |

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
