# Security Policy

Backup Manager runs as root, holds credentials to your backup bucket, and can overwrite live
accounts, so we take its security seriously.

## Supported versions

Only the latest release receives fixes. Update from **WHM → Backup Manager → Check for Updates**.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report it privately through GitHub: open the **Security** tab of this repository and choose
**Report a vulnerability**. Include the version (`cat /opt/skyserver-backup-module/VERSION`),
what an attacker can do and from where (a cPanel account, a reseller, the network), and steps
to reproduce. We aim to acknowledge reports within 3 working days.

## Security model

| Threat | Mitigation |
|---|---|
| A customer restores or reads another account's backup | Requests are checked against the live WHM account list and the `<user>_<db>` naming rule before anything runs. Manifests are `0640 root:<user>` in directories that can be traversed but not listed. |
| A customer bypasses "self-restore off" | Enforced in three places: the page, the request endpoint, and the root worker. |
| A customer obtains storage credentials | Keys never leave `/etc/skyserver-backup.conf` (`0600`). Downloads use one-hour presigned URLs. Keys are never sent to the browser, even in WHM. |
| A customer tampers with another account's request | The request queue is a sticky drop box (`1733`), so each account can only create its own files. |
| Cross-site request forgery | Every change is POST-only, behind WHM's and cPanel's session tokens. |
| A corrupt backup replaces good data | Archives and dumps are verified before upload, and a restore asks for confirmation twice. |
| Over-broad cloud credentials | Use a key limited to the backup bucket. See the policy in the README. |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the spool layout and permissions.
