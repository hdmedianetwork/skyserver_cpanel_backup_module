<?php
/**
 * SkyServer Backup Manager — cPanel end-user UI.
 *
 * Reads the per-user manifest written by bin/backup-user.sh (the plugin
 * never gets S3 credentials) and lets the user request a restore via
 * action.live.php (AJAX). A restore is never performed here: this just
 * drops a request file into the queue that bin/restore-worker.sh
 * (running as root via cron) processes — that's the privilege boundary.
 */

$user = getenv('REMOTE_USER');
if (!$user || !preg_match('/^[a-zA-Z0-9_]+$/', $user)) {
    http_response_code(403);
    die('Unable to determine cPanel user.');
}

$manifestFile = "/var/spool/skyserver-backup/manifests/{$user}.json";
$backups = [];
if (is_readable($manifestFile)) {
    $backups = json_decode(file_get_contents($manifestFile), true) ?: [];
}
$latest = $backups[0] ?? null;
$dbCount = $latest ? count($latest['databases'] ?? []) : 0;
?>
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Backup Manager</title>
<style>
  :root {
    --blue: #2f6fed; --green: #1f9d55; --red: #d64545; --amber: #c98a1f;
    --bg: #f4f6f9; --card: #ffffff; --border: #e3e7ee; --text: #24303f; --muted: #6b7688;
  }
  * { box-sizing: border-box; }
  body { font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
         background: var(--bg); color: var(--text); margin: 0; padding: 24px; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .sub { color: var(--muted); font-size: 13px; margin-bottom: 20px; }
  .stats { display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 24px; }
  .stat { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
          padding: 14px 18px; min-width: 150px; }
  .stat .label { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }
  .stat .value { font-size: 22px; font-weight: 600; margin-top: 4px; }
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
          margin-bottom: 20px; overflow: hidden; }
  .card h2 { font-size: 14px; margin: 0; padding: 14px 18px; border-bottom: 1px solid var(--border);
             background: #fafbfd; }
  table { width: 100%; border-collapse: collapse; }
  th, td { padding: 10px 18px; text-align: left; font-size: 13px; border-bottom: 1px solid var(--border); }
  th { color: var(--muted); font-weight: 600; font-size: 11px; text-transform: uppercase; }
  tr:last-child td { border-bottom: none; }
  .badge { display: inline-block; padding: 2px 9px; border-radius: 99px; font-size: 11px; font-weight: 600; }
  .badge-db { background: #eaf1ff; color: var(--blue); }
  .btn { border: 1px solid var(--border); background: #fff; border-radius: 6px; padding: 6px 12px;
         font-size: 12px; cursor: pointer; color: var(--text); }
  .btn:hover { border-color: var(--blue); color: var(--blue); }
  .btn:disabled { opacity: .5; cursor: default; }
  .status-tag { font-size: 12px; font-weight: 600; padding: 3px 10px; border-radius: 99px; }
  .status-queued  { background: #fff6e3; color: var(--amber); }
  .status-running { background: #eaf1ff; color: var(--blue); }
  .status-success { background: #e8f8ee; color: var(--green); }
  .status-failed  { background: #fdeaea; color: var(--red); }
  .empty { padding: 30px 18px; color: var(--muted); font-size: 13px; text-align: center; }
</style>
</head>
<body>

<h1>Backup Manager</h1>
<div class="sub">Automatic daily backups for <strong><?= htmlspecialchars($user) ?></strong>, stored securely off-server.</div>

<div class="stats">
  <div class="stat">
    <div class="label">Total Backups</div>
    <div class="value"><?= count($backups) ?></div>
  </div>
  <div class="stat">
    <div class="label">Last Backup</div>
    <div class="value"><?= $latest ? htmlspecialchars($latest['date']) : '—' ?></div>
  </div>
  <div class="stat">
    <div class="label">Last Backup Size</div>
    <div class="value"><?= $latest ? htmlspecialchars($latest['full_size'] ?? '—') : '—' ?></div>
  </div>
  <div class="stat">
    <div class="label">Databases</div>
    <div class="value"><?= $dbCount ?></div>
  </div>
</div>

<?php if (empty($backups)): ?>
  <div class="card"><div class="empty">No backups yet — the first daily backup will appear here after it runs.</div></div>
<?php else: ?>

<div class="card">
  <h2>Account Backups</h2>
  <table>
    <tr><th>Date</th><th>Size</th><th style="text-align:right">Action</th></tr>
    <?php foreach ($backups as $b): ?>
    <tr>
      <td><?= htmlspecialchars($b['date']) ?></td>
      <td><?= htmlspecialchars($b['full_size'] ?? '-') ?></td>
      <td style="text-align:right">
        <button class="btn restore-btn" data-type="full" data-date="<?= htmlspecialchars($b['date']) ?>">Restore</button>
        <span class="status-slot"></span>
      </td>
    </tr>
    <?php endforeach; ?>
  </table>
</div>

<div class="card">
  <h2>Database Backups</h2>
  <table>
    <tr><th>Date</th><th>Database</th><th style="text-align:right">Action</th></tr>
    <?php foreach ($backups as $b): foreach (($b['databases'] ?? []) as $db): ?>
    <tr>
      <td><?= htmlspecialchars($b['date']) ?></td>
      <td><span class="badge badge-db"><?= htmlspecialchars($db) ?></span></td>
      <td style="text-align:right">
        <button class="btn restore-btn" data-type="database" data-date="<?= htmlspecialchars($b['date']) ?>" data-db="<?= htmlspecialchars($db) ?>">Restore</button>
        <span class="status-slot"></span>
      </td>
    </tr>
    <?php endforeach; endforeach; ?>
  </table>
</div>

<?php endif; ?>

<script>
document.querySelectorAll('.restore-btn').forEach(function (btn) {
  btn.addEventListener('click', function () {
    var type = btn.dataset.type, date = btn.dataset.date, db = btn.dataset.db || '';
    var label = type === 'full' ? 'your entire account' : ('database "' + db + '"');
    if (!confirm('This will overwrite ' + label + ' with the backup from ' + date + '. Continue?')) return;

    var slot = btn.nextElementSibling;
    btn.disabled = true;
    slot.innerHTML = '<span class="status-tag status-queued">queued</span>';

    fetch('action.live.php', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: type, date: date, db: db })
    }).then(function (r) { return r.json(); }).then(function (res) {
      if (!res.ok) {
        slot.innerHTML = '<span class="status-tag status-failed">error</span> ' + (res.error || '');
        btn.disabled = false;
        return;
      }
      poll(res.id, slot, btn);
    }).catch(function () {
      slot.innerHTML = '<span class="status-tag status-failed">error</span> network error';
      btn.disabled = false;
    });
  });
});

function poll(id, slot, btn) {
  fetch('status.live.php?id=' + encodeURIComponent(id)).then(function (r) { return r.json(); }).then(function (res) {
    if (!res.ok) {
      slot.innerHTML = '<span class="status-tag status-failed">error</span>';
      btn.disabled = false;
      return;
    }
    slot.innerHTML = '<span class="status-tag status-' + res.status + '">' + res.status + '</span>';
    if (res.status === 'success' || res.status === 'failed') {
      if (res.status === 'failed' && res.error) {
        slot.innerHTML += ' <small>' + res.error + '</small>';
      }
      btn.disabled = false;
      return;
    }
    setTimeout(function () { poll(id, slot, btn); }, 3000);
  });
}
</script>

</body>
</html>
