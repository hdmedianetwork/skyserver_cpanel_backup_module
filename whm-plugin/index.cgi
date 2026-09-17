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

function read_conf(): array {
    $conf = [];
    if (is_readable(CONF_FILE)) {
        foreach (file(CONF_FILE) as $line) {
            if (preg_match('/^([A-Z_]+)="?([^"\n]*)"?$/', trim($line), $m)) {
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
        if (preg_match('/^([A-Z_]+)=/', trim($line), $m) && array_key_exists($m[1], $updates)) {
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
    preg_match('/Backup run started: (.+)/', $last, $s);
    preg_match('/Backup run finished: (.+)/', $last, $f);
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
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? '';

    if ($action === 'run_now') {
        $running = trim((string) shell_exec("pgrep -f 'bin/backup-all.sh' 2>/dev/null"));
        if ($running !== '') {
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
        ];
        if (!empty($_POST['aws_key'])) $updates['AWS_ACCESS_KEY_ID'] = $_POST['aws_key'];
        if (!empty($_POST['aws_secret'])) $updates['AWS_SECRET_ACCESS_KEY'] = $_POST['aws_secret'];
        write_conf($updates);
        $message = 'Configuration saved.';
    }
}

$conf = read_conf();
$summary = latest_run_summary();
$rows = account_rows();
$jobs = restore_jobs();
$backupRunning = trim((string) shell_exec("pgrep -f 'bin/backup-all.sh' 2>/dev/null")) !== '';
?>
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SkyServer Backup Manager — Admin</title>
<style>
  :root { --blue:#2f6fed; --green:#1f9d55; --red:#d64545; --amber:#c98a1f;
          --bg:#f4f6f9; --card:#fff; --border:#e3e7ee; --text:#24303f; --muted:#6b7688; }
  * { box-sizing: border-box; }
  body { font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
         background: var(--bg); color: var(--text); margin: 0; padding: 24px; }
  h1 { font-size: 21px; margin: 0 0 4px; }
  .sub { color: var(--muted); font-size: 13px; margin-bottom: 20px; }
  .msg { background: #eaf1ff; border: 1px solid #c6d9fb; color: var(--blue);
         padding: 10px 14px; border-radius: 8px; margin-bottom: 18px; font-size: 13px; }
  .stats { display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 22px; }
  .stat { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
          padding: 14px 18px; min-width: 150px; }
  .stat .label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }
  .stat .value { font-size: 22px; font-weight: 600; margin-top: 4px; }
  .value.ok { color: var(--green); } .value.fail { color: var(--red); }
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
          margin-bottom: 20px; overflow: hidden; }
  .card h2 { font-size: 14px; margin: 0; padding: 14px 18px; border-bottom: 1px solid var(--border);
             background: #fafbfd; display: flex; justify-content: space-between; align-items: center; }
  table { width: 100%; border-collapse: collapse; }
  th, td { padding: 9px 18px; text-align: left; font-size: 13px; border-bottom: 1px solid var(--border); }
  th { color: var(--muted); font-weight: 600; font-size: 11px; text-transform: uppercase; }
  tr:last-child td { border-bottom: none; }
  .tag { font-size: 11px; font-weight: 600; padding: 2px 9px; border-radius: 99px; }
  .tag-success, .tag-ok { background: #e8f8ee; color: var(--green); }
  .tag-failed, .tag-fail { background: #fdeaea; color: var(--red); }
  .tag-running, .tag-queued { background: #eaf1ff; color: var(--blue); }
  .tag-none { background: #f1f3f6; color: var(--muted); }
  .btn { border: 1px solid var(--border); background: #fff; border-radius: 6px; padding: 7px 14px;
         font-size: 13px; cursor: pointer; color: var(--text); }
  .btn-primary { background: var(--blue); border-color: var(--blue); color: #fff; }
  .btn:disabled { opacity: .5; cursor: default; }
  .empty { padding: 26px 18px; color: var(--muted); font-size: 13px; text-align: center; }
  form.config { padding: 16px 18px; display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  form.config label { font-size: 12px; color: var(--muted); display: block; margin-bottom: 4px; }
  form.config input { width: 100%; padding: 7px 10px; border: 1px solid var(--border); border-radius: 6px; font-size: 13px; }
  form.config .full { grid-column: 1 / -1; }
</style>
</head>
<body>

<h1>SkyServer Backup Manager</h1>
<div class="sub">S3 backup status across all cPanel accounts on this server.</div>

<?php if ($message): ?><div class="msg"><?= htmlspecialchars($message) ?></div><?php endif; ?>

<div class="stats">
  <div class="stat"><div class="label">Accounts Protected</div><div class="value"><?= count($rows) ?></div></div>
  <div class="stat"><div class="label">Last Run — Success</div><div class="value ok"><?= $summary['ok'] ?></div></div>
  <div class="stat"><div class="label">Last Run — Failed</div><div class="value fail"><?= $summary['fail'] ?></div></div>
  <div class="stat"><div class="label">Retention</div><div class="value"><?= htmlspecialchars($conf['RETENTION_DAYS'] ?? '—') ?> days</div></div>
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
    <tr><th>User</th><th>Last Backup</th><th>Size</th><th>Databases</th><th>Total Backups</th><th>Status</th></tr>
    <?php foreach ($rows as $r): ?>
    <tr>
      <td><?= htmlspecialchars($r['user']) ?></td>
      <td><?= htmlspecialchars($r['last_date'] ?? '—') ?></td>
      <td><?= htmlspecialchars($r['last_size'] ?? '—') ?></td>
      <td><?= $r['db_count'] ?></td>
      <td><?= $r['total_backups'] ?></td>
      <td><?php if ($r['last_date']): ?><span class="tag tag-ok">backed up</span>
          <?php else: ?><span class="tag tag-none">no backup yet</span><?php endif; ?></td>
    </tr>
    <?php endforeach; ?>
  </table>
  <?php endif; ?>
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
      <label>AWS Region</label>
      <input type="text" name="aws_region" value="<?= htmlspecialchars($conf['AWS_DEFAULT_REGION'] ?? '') ?>">
    </div>
    <div>
      <label>Retention (days)</label>
      <input type="number" min="1" name="retention_days" value="<?= htmlspecialchars($conf['RETENTION_DAYS'] ?? '7') ?>">
    </div>
    <div></div>
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
</div>

</body>
</html>
