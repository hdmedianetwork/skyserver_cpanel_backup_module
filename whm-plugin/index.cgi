#!__PHP_BIN__
<?php
/**
 * SkyServer Backup Manager — WHM admin dashboard (root only, served by
 * WHM/cpsrvd as a CGI script via AppConfig). Gives the admin an overview
 * of every account's backup status, S3 config, and restore job history,
 * without needing shell access for routine checks.
 *
 * The shebang above is rewritten by install.sh to the real PHP binary
 * path on this server.
 */

const CONF_FILE     = '/etc/skyserver-backup.conf';
const LOG_FILE       = '/var/log/skyserver-backup.log';
const MANIFEST_DIR   = '/var/spool/skyserver-backup/manifests';
const STATUS_DIR      = '/var/spool/skyserver-backup/restore-status';
const INSTALL_DIR    = '/opt/skyserver-backup-module';
const LOCK_FILE       = '/var/spool/skyserver-backup/backup.lock';
const USER_RESTORE_MARKER = '/var/spool/skyserver-backup/user-restore-enabled';
const QUEUE_DIR       = '/var/spool/skyserver-backup/restore-requests';
const LOGO_URL        = 'https://ik.imagekit.io/hdmn/skybackupmanager.png';

// bin/backup-all.sh holds an flock on LOCK_FILE for its whole run. Trying
// to (non-blocking) acquire the same lock here tells us if it's busy,
// without the false positives `pgrep -f` gets from matching its own
// `sh -c "..."` invocation string.
function is_backup_running(): bool {
    $exit = trim((string) shell_exec(
        'flock -n ' . escapeshellarg(LOCK_FILE) . ' -c true >/dev/null 2>&1; echo $?'
    ));
    return $exit !== '0';
}

function read_conf(): array {
    $conf = [];
    if (is_readable(CONF_FILE)) {
        foreach (file(CONF_FILE) as $line) {
            if (preg_match('/^([A-Z0-9_]+)="?([^"\n]*)"?$/', trim($line), $m)) {
                $conf[$m[1]] = $m[2];
            }
        }
    }
    return $conf;
}

function write_conf(array $updates): void {
    $lines = is_readable(CONF_FILE) ? file(CONF_FILE, FILE_IGNORE_NEW_LINES) : [];
    $seen = [];
    foreach ($lines as &$line) {
        if (preg_match('/^([A-Z0-9_]+)=/', trim($line), $m) && array_key_exists($m[1], $updates)) {
            if ($updates[$m[1]] !== null) {
                $line = $m[1] . '="' . addcslashes($updates[$m[1]], '"\\') . '"';
            }
            $seen[$m[1]] = true;
        }
    }
    unset($line);
    foreach ($updates as $key => $val) {
        if ($val !== null && empty($seen[$key])) {
            $lines[] = $key . '="' . addcslashes($val, '"\\') . '"';
        }
    }
    file_put_contents(CONF_FILE, implode("\n", $lines) . "\n");
    @chmod(CONF_FILE, 0600);
}

function whm_accounts(): array {
    $out = shell_exec('whmapi1 listaccts --output=jsonpretty 2>/dev/null');
    preg_match_all('/"user"\s*:\s*"([^"]+)"/', $out ?? '', $m);
    return $m[1] ?? [];
}

function latest_run_summary(): array {
    if (!is_readable(LOG_FILE)) return ['ok' => 0, 'fail' => 0, 'started' => null, 'finished' => null];
    $content = file_get_contents(LOG_FILE);
    $chunks = preg_split('/(?====== Backup run started)/', $content);
    $last = end($chunks) ?: '';
    preg_match('/Backup run started: (.+?) =====/', $last, $s);
    preg_match('/Backup run finished: (.+?) =====/', $last, $f);
    return [
        'ok'       => substr_count($last, '[OK]'),
        'fail'     => substr_count($last, '[FAIL]'),
        'started'  => $s[1] ?? null,
        'finished' => $f[1] ?? null,
        'failed_users' => array_values(array_filter(array_map(function ($l) {
            return preg_match('/\[FAIL\] (\S+)/', $l, $mm) ? $mm[1] : null;
        }, explode("\n", $last)))),
    ];
}

function account_rows(): array {
    $accounts = whm_accounts();
    $rows = [];
    foreach ($accounts as $user) {
        $manifestFile = MANIFEST_DIR . "/$user.json";
        $latest = null;
        $total = 0;
        if (is_readable($manifestFile)) {
            $data = json_decode(file_get_contents($manifestFile), true) ?: [];
            $latest = $data[0] ?? null;
            $total = count($data);
        }
        $rows[] = [
            'user' => $user,
            'last_date' => $latest['date'] ?? null,
            'last_size' => $latest['full_size'] ?? null,
            'db_count' => $latest ? count($latest['databases'] ?? []) : 0,
            'total_backups' => $total,
        ];
    }
    return $rows;
}

function normalize_endpoint(string $url): string {
    $url = trim($url);
    // The AWS CLI refuses an endpoint with no scheme, and typing the bare
    // hostname is the easy mistake — fix it on the way in.
    if ($url !== '' && !preg_match('#^https?://#i', $url)) {
        $url = 'https://' . $url;
    }
    return $url;
}

function account_backups(string $user): array {
    $f = MANIFEST_DIR . "/$user.json";
    return is_readable($f) ? (json_decode(file_get_contents($f), true) ?: []) : [];
}

function backup_log_tail(int $lines = 120): string {
    if (!is_readable(LOG_FILE)) return '(no log yet)';
    $out = shell_exec('tail -n ' . (int) $lines . ' ' . escapeshellarg(LOG_FILE) . ' 2>/dev/null');
    return $out !== null && $out !== '' ? $out : '(log is empty)';
}

function restore_jobs(int $limit = 20): array {
    $files = glob(STATUS_DIR . '/*.json') ?: [];
    usort($files, fn($a, $b) => filemtime($b) <=> filemtime($a));
    $jobs = [];
    foreach (array_slice($files, 0, $limit) as $f) {
        $data = json_decode(file_get_contents($f), true) ?: [];
        $data['file_time'] = filemtime($f);
        $jobs[] = $data;
    }
    return $jobs;
}

$message = '';
$updateAvailable = false;
$updateLog = '';
$s3TestOutput = '';
$conf = read_conf();

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? '';

    if ($action === 'run_now') {
        if (is_backup_running()) {
            $message = 'A backup run is already in progress.';
        } else {
            shell_exec('nohup ' . escapeshellarg(INSTALL_DIR . '/bin/backup-all.sh') . ' > /dev/null 2>&1 &');
            $message = 'Backup run started in the background — refresh in a minute to see progress.';
        }
    } elseif ($action === 'save_config') {
        $updates = [
            'S3_BUCKET' => $_POST['s3_bucket'] ?? null,
            'AWS_DEFAULT_REGION' => $_POST['aws_region'] ?? null,
            'RETENTION_DAYS' => $_POST['retention_days'] ?? null,
            'BACKUP_WORK_DIR' => $_POST['work_dir'] ?? null,
            'DISK_SAFETY_MARGIN_MB' => $_POST['disk_margin'] ?? null,
            'ENABLE_USER_RESTORE' => (($_POST['user_restore'] ?? '0') === '1') ? '1' : '0',
            'ALERT_EMAIL' => $_POST['alert_email'] ?? null,
            'S3_ENDPOINT_URL' => normalize_endpoint($_POST['s3_endpoint'] ?? ''),
            'S3_ADDRESSING_STYLE' => in_array($_POST['addressing_style'] ?? '', ['path', 'virtual'], true)
                ? $_POST['addressing_style'] : 'path',
        ];
        if (!empty($_POST['aws_key'])) $updates['AWS_ACCESS_KEY_ID'] = $_POST['aws_key'];
        if (!empty($_POST['aws_secret'])) $updates['AWS_SECRET_ACCESS_KEY'] = $_POST['aws_secret'];
        write_conf($updates);

        // restore-worker.sh syncs this marker every minute, but do it now
        // so the setting takes effect on the user's next page load.
        if ($updates['ENABLE_USER_RESTORE'] === '1') {
            touch(USER_RESTORE_MARKER);
            chmod(USER_RESTORE_MARKER, 0644);
        } else {
            @unlink(USER_RESTORE_MARKER);
        }

        $message = 'Configuration saved.';

    } elseif ($action === 'backup_user') {
        $target = preg_replace('/[^a-zA-Z0-9_]/', '', $_POST['user'] ?? '');
        if ($target === '' || !in_array($target, whm_accounts(), true)) {
            $message = 'Unknown account.';
        } elseif (is_backup_running()) {
            $message = 'A backup run is already in progress — try again once it finishes.';
        } else {
            shell_exec('nohup ' . escapeshellarg(INSTALL_DIR . '/bin/backup-user.sh') . ' '
                . escapeshellarg($target) . ' >> ' . escapeshellarg(LOG_FILE) . ' 2>&1 &');
            $message = "Backup of $target started in the background — check the log below in a minute.";
        }

    } elseif ($action === 'admin_restore') {
        $target = preg_replace('/[^a-zA-Z0-9_]/', '', $_POST['user'] ?? '');
        $date   = preg_replace('/[^0-9\-]/', '', $_POST['date'] ?? '');
        $db     = preg_replace('/[^a-zA-Z0-9_]/', '', $_POST['db'] ?? '');
        $type   = ($db !== '') ? 'database' : 'full';

        $valid = false;
        foreach (account_backups($target) as $b) {
            if (($b['date'] ?? '') === $date) {
                $valid = ($type === 'full') || in_array($db, $b['databases'] ?? [], true);
            }
        }

        if (!$valid) {
            $message = 'That backup does not exist for that account.';
        } else {
            // Queued with source=admin so restore-worker.sh runs it even
            // while user self-restore is switched off.
            $id = uniqid('req_', true);
            $req = ['id' => $id, 'user' => $target, 'type' => $type, 'date' => $date, 'source' => 'admin'];
            if ($type === 'database') $req['db'] = $db;
            file_put_contents(QUEUE_DIR . "/$id.json", json_encode($req));
            $what = $type === 'full' ? "full account" : "database $db";
            $message = "Restore of $what for $target queued — it starts within a minute. Watch Recent Restore Jobs.";
        }

    } elseif ($action === 'test_s3') {
        // bin/s3-test.sh reads the same config the backup jobs do, so the
        // test exercises exactly the path a real run takes — including the
        // custom endpoint for S3-compatible providers.
        $s3TestOutput = trim((string) shell_exec(
            escapeshellarg(INSTALL_DIR . '/bin/s3-test.sh') . ' 2>&1'));
        $message = str_contains($s3TestOutput, 'All checks passed')
            ? 'S3 test passed.'
            : 'S3 test reported a problem — see the output below.';

    } elseif ($action === 'update_check') {
        $out = trim((string) shell_exec(
            escapeshellarg(INSTALL_DIR . '/bin/self-update.sh') . ' check 2>&1'));
        if (str_ends_with($out, 'update')) {
            preg_match('/local (\S+) remote (\S+)/', $out, $m);
            $updateAvailable = true;
            $message = "This server is on version {$m[1]}; GitHub has {$m[2]}. Hit \"Install Update\" to sync.";
        } elseif (str_ends_with($out, 'current')) {
            preg_match('/local (\S+)/', $out, $m);
            $message = "You are up to date (version {$m[1]}).";
        } else {
            $message = 'Update check failed: could not reach GitHub.';
        }

    } elseif ($action === 'update_apply') {
        $out = shell_exec(escapeshellarg(INSTALL_DIR . '/bin/self-update.sh') . ' apply 2>&1');
        $updateLog = trim((string) $out);
        $message = str_contains($updateLog, 'Updated to version')
            ? 'Module updated successfully.'
            : 'Update failed — see the output below.';
    }
}

$conf = read_conf();   // re-read: a save above may have changed it
$summary = latest_run_summary();
$rows = account_rows();
$jobs = restore_jobs();
$backupRunning = is_backup_running();
$userRestore = (($conf['ENABLE_USER_RESTORE'] ?? '0') === '1');
$version = trim((string) @file_get_contents(INSTALL_DIR . '/VERSION')) ?: 'unknown';

// Feeds the admin restore form's date/database dropdowns without a round trip.
$backupsByUser = [];
foreach ($rows as $r) {
    $backupsByUser[$r['user']] = account_backups($r['user']);
}
?>
<?php
// Every rule is scoped under .sky. When this page renders inside WHM's own
// chrome, bare element selectors like `table` or `h1` would otherwise
// restyle WHM's sidebar and headings too.
$SKY_STYLES = <<<'CSS'
<style>
  .sky { --blue:#2f6fed; --green:#1f9d55; --red:#d64545; --amber:#c98a1f;
         --bg:#f4f6f9; --card:#fff; --border:#e3e7ee; --text:#24303f; --muted:#6b7688;
         font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
         color: var(--text); padding: 20px; }
  .sky * { box-sizing: border-box; }
  .sky h1 { font-size: 21px; margin: 0 0 4px; }
  .sky .sub { color: var(--muted); font-size: 13px; margin-bottom: 20px; }
  .sky .msg { background: #eaf1ff; border: 1px solid #c6d9fb; color: var(--blue);
         padding: 10px 14px; border-radius: 8px; margin-bottom: 18px; font-size: 13px; }
  .sky .stats { display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 22px; }
  .sky .stat { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
          padding: 14px 18px; min-width: 150px; }
  .sky .stat .label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }
  .sky .stat .value { font-size: 22px; font-weight: 600; margin-top: 4px; }
  .sky .value.ok { color: var(--green); } .sky .value.fail { color: var(--red); }
  .sky .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
          margin-bottom: 20px; overflow: hidden; }
  .sky .card h2 { font-size: 14px; margin: 0; padding: 14px 18px; border-bottom: 1px solid var(--border);
             background: #fafbfd; display: flex; justify-content: space-between; align-items: center; }
  .sky table { width: 100%; border-collapse: collapse; margin: 0; }
  .sky th, .sky td { padding: 9px 18px; text-align: left; font-size: 13px;
                     border-bottom: 1px solid var(--border); background: none; }
  .sky th { color: var(--muted); font-weight: 600; font-size: 11px; text-transform: uppercase; }
  .sky tr:last-child td { border-bottom: none; }
  .sky .tag { font-size: 11px; font-weight: 600; padding: 2px 9px; border-radius: 99px; }
  .sky .tag-success, .sky .tag-ok { background: #e8f8ee; color: var(--green); }
  .sky .tag-failed, .sky .tag-fail { background: #fdeaea; color: var(--red); }
  .sky .tag-running, .sky .tag-queued { background: #eaf1ff; color: var(--blue); }
  .sky .tag-none { background: #f1f3f6; color: var(--muted); }
  .sky .btn { border: 1px solid var(--border); background: #fff; border-radius: 6px; padding: 7px 14px;
         font-size: 13px; cursor: pointer; color: var(--text); }
  .sky .btn-primary { background: var(--blue); border-color: var(--blue); color: #fff; }
  .sky .btn:disabled { opacity: .5; cursor: default; }
  .sky .empty { padding: 26px 18px; color: var(--muted); font-size: 13px; text-align: center; }
  .sky form.config { padding: 16px 18px; display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .sky form.config label { font-size: 12px; color: var(--muted); display: block; margin-bottom: 4px; }
  .sky form.config input { width: 100%; padding: 7px 10px; border: 1px solid var(--border); border-radius: 6px; font-size: 13px; }
  .sky form.config .full { grid-column: 1 / -1; }
  .sky form.config select { width: 100%; padding: 7px 10px; border: 1px solid var(--border); border-radius: 6px; font-size: 13px; }
  .sky .brand { display: flex; align-items: center; gap: 14px; margin-bottom: 20px; }
  .sky .brand img { height: 46px; width: auto; max-width: 210px; display: block; }
  .sky .brand h1 { margin: 0 0 2px; }
  .sky .brand-actions { margin: 0 0 0 auto; }
  .sky .logbox { margin: 0; padding: 14px 18px; background: #1e2530; color: #d6dde8;
            font-size: 12px; line-height: 1.5; max-height: 340px; overflow: auto;
            white-space: pre-wrap; word-break: break-word; }
  .sky form.inline { display: inline; margin: 0; }
  .sky .restore-form { padding: 16px 18px; display: flex; gap: 12px; flex-wrap: wrap; align-items: flex-end; }
  .sky .restore-form label { font-size: 12px; color: var(--muted); display: block; margin-bottom: 4px; }
  .sky .restore-form select { padding: 7px 10px; border: 1px solid var(--border); border-radius: 6px;
                         font-size: 13px; min-width: 165px; }
</style>
CSS;

// Buffer the page body so it can be dropped either into WHM's own chrome
// or into a standalone document, without writing the markup twice.
ob_start();
?>

<div class="brand">
  <img src="<?= LOGO_URL ?>" alt="SkyServer Backup Manager">
  <div>
    <h1>SkyServer Backup Manager</h1>
    <div class="sub" style="margin:0">S3 backup status across all cPanel accounts on this server. &middot; v<?= htmlspecialchars($version) ?></div>
  </div>
  <form method="post" class="brand-actions">
    <button class="btn" name="action" value="update_check">Check for Updates</button>
  </form>
</div>

<?php if ($message): ?><div class="msg"><?= htmlspecialchars($message) ?></div><?php endif; ?>

<?php if ($updateAvailable): ?>
<form method="post" class="msg" style="background:#e8f8ee; border-color:#bfe6cd; color:#1f7a45">
  A newer version is available on GitHub.
  <button class="btn btn-primary" name="action" value="update_apply" style="margin-left:10px"
          onclick="return confirm('Pull the latest code from GitHub and redeploy? Your config and existing backups are not touched.');">
    Install Update
  </button>
</form>
<?php endif; ?>

<?php if ($updateLog !== ''): ?>
  <div class="card"><h2>Update Output</h2><pre class="logbox"><?= htmlspecialchars($updateLog) ?></pre></div>
<?php endif; ?>

<div class="stats">
  <div class="stat"><div class="label">Accounts Protected</div><div class="value"><?= count($rows) ?></div></div>
  <div class="stat"><div class="label">Last Run — Success</div><div class="value ok"><?= $summary['ok'] ?></div></div>
  <div class="stat"><div class="label">Last Run — Failed</div><div class="value fail"><?= $summary['fail'] ?></div></div>
  <div class="stat"><div class="label">Retention</div><div class="value"><?= htmlspecialchars($conf['RETENTION_DAYS'] ?? '—') ?> days</div></div>
  <div class="stat">
    <div class="label">User Self-Restore</div>
    <div class="value" style="font-size:16px; padding-top:6px">
      <span class="tag <?= $userRestore ? 'tag-ok' : 'tag-none' ?>"><?= $userRestore ? 'enabled' : 'disabled' ?></span>
    </div>
  </div>
</div>

<div class="card">
  <h2>
    Backup Runs
    <form method="post" style="margin:0">
      <input type="hidden" name="action" value="run_now">
      <button class="btn btn-primary" <?= $backupRunning ? 'disabled' : '' ?>>
        <?= $backupRunning ? 'Backup running…' : 'Run Backup Now' ?>
      </button>
    </form>
  </h2>
  <div style="padding:14px 18px; font-size:13px; color: var(--muted)">
    Last started: <?= htmlspecialchars($summary['started'] ?? 'never') ?><br>
    Last finished: <?= htmlspecialchars($summary['finished'] ?? '—') ?>
    <?php if (!empty($summary['failed_users'])): ?>
      <br>Failed accounts: <?= htmlspecialchars(implode(', ', $summary['failed_users'])) ?>
    <?php endif; ?>
  </div>
</div>

<div class="card">
  <h2>Accounts</h2>
  <?php if (empty($rows)): ?>
    <div class="empty">No cPanel accounts found via whmapi1.</div>
  <?php else: ?>
  <table>
    <tr><th>User</th><th>Last Backup</th><th>Size</th><th>Databases</th><th>Total Backups</th><th>Status</th><th style="text-align:right">Action</th></tr>
    <?php foreach ($rows as $r): ?>
    <tr>
      <td><?= htmlspecialchars($r['user']) ?></td>
      <td><?= htmlspecialchars($r['last_date'] ?? '—') ?></td>
      <td><?= htmlspecialchars($r['last_size'] ?? '—') ?></td>
      <td><?= $r['db_count'] ?></td>
      <td><?= $r['total_backups'] ?></td>
      <td><?php if ($r['last_date']): ?><span class="tag tag-ok">backed up</span>
          <?php else: ?><span class="tag tag-none">no backup yet</span><?php endif; ?></td>
      <td style="text-align:right">
        <form method="post" class="inline">
          <input type="hidden" name="user" value="<?= htmlspecialchars($r['user']) ?>">
          <button class="btn" name="action" value="backup_user" <?= $backupRunning ? 'disabled' : '' ?>>Back Up Now</button>
        </form>
      </td>
    </tr>
    <?php endforeach; ?>
  </table>
  <?php endif; ?>
</div>

<div class="card">
  <h2>Restore an Account</h2>
  <form method="post" class="restore-form"
        onsubmit="return confirm('This overwrites the live data for the selected account and cannot be undone. Continue?');">
    <input type="hidden" name="action" value="admin_restore">
    <div>
      <label>Account</label>
      <select name="user" id="ra-user" required>
        <option value="">— select —</option>
        <?php foreach ($rows as $r): if (!$r['last_date']) continue; ?>
          <option value="<?= htmlspecialchars($r['user']) ?>"><?= htmlspecialchars($r['user']) ?></option>
        <?php endforeach; ?>
      </select>
    </div>
    <div>
      <label>Backup date</label>
      <select name="date" id="ra-date" required><option value="">— select account first —</option></select>
    </div>
    <div>
      <label>What to restore</label>
      <select name="db" id="ra-db"><option value="">Full account</option></select>
    </div>
    <div><button class="btn btn-primary" type="submit">Restore</button></div>
  </form>
  <div style="padding: 0 18px 16px; font-size: 12px; color: var(--muted)">
    Runs as admin, so it works even while user self-restore is switched off — use this to test a restore on a throwaway account before enabling it for customers.
  </div>
</div>

<div class="card">
  <h2>Recent Restore Jobs</h2>
  <?php if (empty($jobs)): ?>
    <div class="empty">No restore jobs have been requested yet.</div>
  <?php else: ?>
  <table>
    <tr><th>User</th><th>Status</th><th>Updated</th><th>Detail</th></tr>
    <?php foreach ($jobs as $j): ?>
    <tr>
      <td><?= htmlspecialchars($j['user'] ?? '—') ?></td>
      <td><span class="tag tag-<?= htmlspecialchars($j['status'] ?? 'none') ?>"><?= htmlspecialchars($j['status'] ?? 'unknown') ?></span></td>
      <td><?= htmlspecialchars($j['updated_at'] ?? date('c', $j['file_time'])) ?></td>
      <td><?= htmlspecialchars($j['error'] ?? '') ?></td>
    </tr>
    <?php endforeach; ?>
  </table>
  <?php endif; ?>
</div>

<div class="card">
  <h2>S3 &amp; Retention Configuration</h2>
  <form class="config" method="post">
    <input type="hidden" name="action" value="save_config">
    <div>
      <label>S3 Bucket</label>
      <input type="text" name="s3_bucket" value="<?= htmlspecialchars($conf['S3_BUCKET'] ?? '') ?>">
    </div>
    <div>
      <label>Region</label>
      <input type="text" name="aws_region" value="<?= htmlspecialchars($conf['AWS_DEFAULT_REGION'] ?? '') ?>">
    </div>
    <div>
      <label>S3 Endpoint URL — blank for Amazon S3; set it for any S3-compatible provider</label>
      <input type="text" name="s3_endpoint" placeholder="https://s3.example-provider.com"
             value="<?= htmlspecialchars($conf['S3_ENDPOINT_URL'] ?? '') ?>">
    </div>
    <div>
      <label>URL style (only used with a custom endpoint)</label>
      <select name="addressing_style">
        <option value="path" <?= (($conf['S3_ADDRESSING_STYLE'] ?? 'path') === 'path') ? 'selected' : '' ?>>Path — endpoint.com/bucket (safe for bucket names containing a dot)</option>
        <option value="virtual" <?= (($conf['S3_ADDRESSING_STYLE'] ?? '') === 'virtual') ? 'selected' : '' ?>>Virtual host — bucket.endpoint.com</option>
      </select>
    </div>
    <div>
      <label>Retention (days)</label>
      <input type="number" min="1" name="retention_days" value="<?= htmlspecialchars($conf['RETENTION_DAYS'] ?? '7') ?>">
    </div>
    <div>
      <label>Alert email on backup failure (blank = no alerts)</label>
      <input type="text" name="alert_email" value="<?= htmlspecialchars($conf['ALERT_EMAIL'] ?? '') ?>">
    </div>
    <div>
      <label>Backup staging directory</label>
      <input type="text" name="work_dir" value="<?= htmlspecialchars($conf['BACKUP_WORK_DIR'] ?? '/root') ?>">
    </div>
    <div>
      <label>Disk safety margin (MB)</label>
      <input type="number" min="0" name="disk_margin" value="<?= htmlspecialchars($conf['DISK_SAFETY_MARGIN_MB'] ?? '2048') ?>">
    </div>
    <div class="full">
      <label>Let cPanel users restore their own backups</label>
      <select name="user_restore">
        <option value="0" <?= $userRestore ? '' : 'selected' ?>>Disabled — users can only view backups (recommended until you've tested a restore)</option>
        <option value="1" <?= $userRestore ? 'selected' : '' ?>>Enabled — users can restore their own account or databases</option>
      </select>
    </div>
    <div>
      <label>AWS Access Key ID (leave blank to keep unchanged)</label>
      <input type="password" name="aws_key" placeholder="••••••••••••">
    </div>
    <div>
      <label>AWS Secret Access Key (leave blank to keep unchanged)</label>
      <input type="password" name="aws_secret" placeholder="••••••••••••">
    </div>
    <div class="full">
      <button class="btn btn-primary" type="submit">Save Configuration</button>
    </div>
  </form>
  <form method="post" style="padding: 0 18px 16px">
    <button class="btn" name="action" value="test_s3">Test S3 Connection</button>
    <span style="font-size:12px; color: var(--muted); margin-left:8px">
      Checks reachability, credentials, and the write + delete permissions a real backup needs.
    </span>
  </form>
  <?php if ($s3TestOutput !== ''): ?>
    <pre class="logbox"><?= htmlspecialchars($s3TestOutput) ?></pre>
  <?php endif; ?>
</div>

<div class="card">
  <h2>
    Backup Log
    <form method="post" class="inline"><button class="btn" name="action" value="refresh_log">Refresh</button></form>
  </h2>
  <pre class="logbox"><?= htmlspecialchars(backup_log_tail(120)) ?></pre>
</div>

<script>
// Backups per account, so the restore form's dropdowns can be filled in
// without another request.
var BACKUPS = <?= json_encode($backupsByUser) ?>;

var userSel = document.getElementById('ra-user');
var dateSel = document.getElementById('ra-date');
var dbSel   = document.getElementById('ra-db');

userSel.addEventListener('change', function () {
  var list = BACKUPS[userSel.value] || [];
  dateSel.innerHTML = list.length
    ? list.map(function (b) { return '<option value="' + b.date + '">' + b.date + ' (' + (b.full_size || '?') + ')</option>'; }).join('')
    : '<option value="">no backups</option>';
  fillDatabases();
});

dateSel.addEventListener('change', fillDatabases);

function fillDatabases() {
  var list = BACKUPS[userSel.value] || [];
  var entry = list.filter(function (b) { return b.date === dateSel.value; })[0];
  var dbs = (entry && entry.databases) || [];
  dbSel.innerHTML = '<option value="">Full account</option>' +
    dbs.map(function (d) { return '<option value="' + d + '">Only database: ' + d + '</option>'; }).join('');
}
</script>
<?php
$body = ob_get_clean();

/**
 * WHM's own header/footer (sidebar, breadcrumb, session token) come from
 * the Perl module Whostmgr::HTMLInterface. Shell out to it and reuse the
 * real chrome rather than approximating it. Run from inside this CGI the
 * child inherits the WHM session environment, so the nav links are live.
 */
function whm_chrome(string $fn, array $args = []): string {
    $perl = '/usr/local/cpanel/3rdparty/bin/perl';
    if (!is_executable($perl)) return '';
    $cmd = escapeshellarg($perl) . ' -e ' . escapeshellarg(
        'use Whostmgr::HTMLInterface (); Whostmgr::HTMLInterface::' . $fn . '(@ARGV);'
    );
    foreach ($args as $a) {
        $cmd .= ' ' . escapeshellarg($a);
    }
    $out = shell_exec($cmd . ' 2>/dev/null');
    return is_string($out) ? $out : '';
}

$header = whm_chrome('defheader', ['SkyServer Backup Manager', '', '/cgi/skyserver_backup/index.cgi']);

// Only trust the chrome if it actually came back as a document; otherwise
// fall back to a standalone page rather than emitting something broken.
if (stripos($header, '<html') !== false) {
    echo $header;
    echo $SKY_STYLES;
    echo '<div class="sky">' . $body . '</div>';
    echo whm_chrome('deffooter');
} else {
    echo "<!DOCTYPE html>\n<html>\n<head>\n";
    echo '<meta charset="utf-8">' . "\n";
    echo '<meta name="viewport" content="width=device-width, initial-scale=1">' . "\n";
    echo "<title>SkyServer Backup Manager</title>\n";
    echo $SKY_STYLES;
    echo "<style>body { margin:0; background:#f4f6f9; }</style>\n";
    echo "</head>\n<body>\n";
    echo '<div class="sky">' . $body . '</div>';
    echo "\n</body>\n</html>\n";
}
