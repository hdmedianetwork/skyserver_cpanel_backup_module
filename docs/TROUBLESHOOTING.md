# Troubleshooting

Problems that have come up on real servers, what caused them, and the fix. Most were fixed in a
release, so the first step is always to update:

```bash
/opt/skyserver-backup-module/bin/self-update.sh apply
```

## Nightly backups do nothing, and every restore says "unknown user"

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

## A restore fails with "unknown user" for an account that plainly exists

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

## The nightly run stops on one account and never moves on

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

## A restore fails with "full account restore failed"

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

## A bucket name with a dot in it

`my.bucket` cannot be reached with virtual-host addressing — the bucket
becomes a subdomain and a wildcard certificate matches one label only, so
every upload fails its TLS handshake. Path style is selected automatically
for such a bucket now, on real Amazon S3 as well as on a custom endpoint.

## The WHM dashboard lists an account's backups, but the account's own Backup Manager page says "No backups yet"

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

## `mysqldump: Got error: 1045: "Access denied for user 'root'@'localhost' (using password: NO)"`

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
