# Changelog

All notable changes to SkyServer Backup Manager are listed here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Fixes for problems seen on live servers are explained
in more depth in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## 0.10.1 · 2026-11-12
### Fixed
- **Find terminated accounts** in WHM failed with *whmapi1 listaccts did not succeed* and archived
  nothing. whmapi1 started from the WHM page inherited the page's CGI environment, and its stderr
  was read together with its reply, so the reply could not be parsed. Every whmapi1 call these
  scripts make now runs with a clean environment and reads stdout only.
- After **Install update**, the page now reloads so the new version's tabs appear.

## 0.10.0 · 2026-11-12
### Added
- **Restore terminated accounts.** When an account is terminated its backups are moved out of the
  nightly retention to `terminated/<user>/<stamp>/` and kept for `TERMINATED_RETENTION_DAYS`
  (default 90). A new **Terminated** tab in WHM lists them and recreates the account from any
  stored day with `/scripts/restorepkg`.
- A final backup is taken as an account is terminated (`TERMINATION_FINAL_BACKUP`, on by default),
  through a non-blocking `Accounts::Remove` hook.
- Accounts terminated before this version are found and archived on update and every night.

### Fixed
- A terminated account's last backups were deleted `RETENTION_DAYS` after termination.
- A new account created with a terminated account's username could see, download and restore the
  previous customer's backups.
- The restore worker trusted the `user` and `source` fields of a request file. A file written by an
  account is now honoured only for that account, and only root can queue an admin request.

## 0.9.4 · 2026-10-17
### Fixed
- Retention now prunes each account's manifest as well as S3. The **Kept** column and the restore
  lists used to grow by one backup a night forever, listing days the bucket no longer had, so an
  account showed 27 kept with retention set to 7. Updating the module corrects existing manifests
  straight away.

## 0.9.3 · 2026-09-18
### Fixed
- A crashed database table no longer costs the account its whole backup. The account is kept and
  marked **partial**, with the databases that failed named. `MYSQL_AUTO_REPAIR` can repair the table
  and retry.
- An account too large for `/root` is staged on another filesystem with room
  (`BACKUP_WORK_DIR_FALLBACK`). When none has room, the failure lists every filesystem checked.

## 0.9.2 · 2026-09-18
### Changed
- **Resume** is offered based on what is actually in S3 today, so it still works after a crash
  that lost the run's state file.

## 0.9.1 · 2026-09-18
### Added
- Failed accounts show the reason, there is a **Show only problems** filter, and each failed
  account has a **Retry** button.

## 0.9.0 · 2026-09-18
### Added
- An interrupted run can be resumed where it stopped (`backup-all.sh --resume`), with live
  *N of M* progress.

## 0.8.3 · 2026-09-18
### Fixed
- One hanging account could stall the whole night, and every night after it. Each account now has
  a time limit (`ACCOUNT_TIMEOUT_MIN`), and the run lock no longer leaks to child processes.

## 0.8.2 · 2026-09-18
### Fixed
- A failed restore now says why: whether the backup couldn't be fetched, or cPanel refused the
  restore.

## 0.8.1 · 2026-09-18
### Fixed
- A temporary WHM API error was reported as *unknown user*, and the restore request was deleted.
  Restores no longer run twice at once.

## 0.8.0 · 2026-09-18
### Added
- Live progress for customers while their backup is packaged, uploaded, fetched or restored.

## 0.7.1 · 2026-09-18
### Fixed
- Nightly backups ran with cron's bare `PATH` and quietly backed up nothing. cPanel's tools are now
  on the path, and missing tools stop the run with a clear reason.

## 0.7.0 · 2026-09-18
### Changed
- WHM and cPanel pages share one design system, with light and dark themes, at full page width.

## 0.6.0 · 2026-09-18
### Changed
- The WHM dashboard is rebuilt as a single page that never reloads.

## 0.5.0 – 0.5.1 · 2026-09-17 – 2026-09-18
### Fixed
- The customer page could not read its own backup list ("No backups yet"). The menu logo now
  ships as both PNG and SVG.

## 0.4.0 – 0.4.9 · 2026-09-17
### Added
- The admin panel renders inside WHM, and the customer page inside cPanel.
### Fixed
- Root's MySQL credentials are passed explicitly. Account databases are found even when `uapi`
  doesn't answer. CGI headers and request parsing work in the WHM panel. The cPanel menu entry
  and icon now appear where each theme reads them.

## 0.3.0 – 0.3.1 · 2026-09-17
### Added
- S3-compatible providers (Wasabi, Backblaze B2, MinIO, …), and a connection test that checks
  write access.

## 0.2.0 – 0.2.2 · 2026-09-17
### Added
- Admin restore, per-account backup, S3 test, one-click updates, and customer downloads.
### Fixed
- WHM plugin registration.

## 0.1.0 · 2026-09-17
### Added
- First release: nightly S3 backup engine, installer, and customer restore page.
