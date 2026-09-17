<?php
/**
 * SkyServer Backup Manager — cPanel end-user UI.
 *
 * Reads the per-user manifest written by bin/backup-user.sh (the plugin
 * never gets S3 credentials) and lets the user request a restore. A
 * restore is never performed here: this just drops a request file into
 * the queue that bin/restore-worker.sh (running as root via cron)
 * processes. This is the privilege boundary — a cPanel user's PHP
 * process cannot run restorepkg or import arbitrary databases itself.
 */

$user = getenv('REMOTE_USER');
if (!$user || !preg_match('/^[a-zA-Z0-9_]+$/', $user)) {
    http_response_code(403);
    die('Unable to determine cPanel user.');
}

$manifestFile = "/var/spool/skyserver-backup/manifests/{$user}.json";
$queueDir     = "/var/spool/skyserver-backup/restore-requests";
$statusDir    = "/var/spool/skyserver-backup/restore-status";

$backups = [];
if (is_readable($manifestFile)) {
    $backups = json_decode(file_get_contents($manifestFile), true) ?: [];
}

$message = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST' && ($_POST['action'] ?? '') === 'restore') {
    $type = ($_POST['type'] ?? '') === 'database' ? 'database' : 'full';
    $date = preg_replace('/[^0-9\-]/', '', $_POST['date'] ?? '');
    $db   = preg_replace('/[^a-zA-Z0-9_]/', '', $_POST['db'] ?? '');

    $validDate = false;
    $validDb = ($type !== 'database');
    foreach ($backups as $b) {
        if ($b['date'] === $date) {
            $validDate = true;
            if ($type === 'database' && in_array($db, $b['databases'] ?? [], true)) {
                $validDb = true;
            }
        }
    }

    if ($validDate && $validDb && is_dir($queueDir) && is_writable($queueDir)) {
        $id = uniqid('req_', true);
        $req = ['id' => $id, 'user' => $user, 'type' => $type, 'date' => $date];
        if ($type === 'database') {
            $req['db'] = $db;
        }
        file_put_contents("$queueDir/$id.json", json_encode($req));
        $message = 'Restore request submitted. It will run within a minute — refresh this page to check status.';
    } else {
        $message = 'Could not submit restore request. Please contact support if this persists.';
    }
}
?>
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Backup Manager</title>
  <style>
    body { font-family: sans-serif; margin: 20px; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 30px; }
    th, td { border: 1px solid #ddd; padding: 8px 12px; text-align: left; }
    th { background: #f4f4f4; }
    button { padding: 4px 10px; cursor: pointer; }
    .msg { padding: 10px; background: #eef7ee; border: 1px solid #b7d8b7; margin-bottom: 15px; }
  </style>
</head>
<body>
<h1>Backup Manager</h1>

<?php if ($message): ?>
  <div class="msg"><?= htmlspecialchars($message) ?></div>
<?php endif; ?>

<?php if (empty($backups)): ?>
  <p>No backups found yet. Backups run automatically once a day.</p>
<?php else: ?>

<h2>Account Backups</h2>
<table>
  <tr><th>Date</th><th>Size</th><th>Action</th></tr>
  <?php foreach ($backups as $b): ?>
  <tr>
    <td><?= htmlspecialchars($b['date']) ?></td>
    <td><?= htmlspecialchars($b['full_size'] ?? '-') ?></td>
    <td>
      <form method="post" onsubmit="return confirm('This will overwrite your current account data with the backup from <?= htmlspecialchars($b['date']) ?>. Continue?');">
        <input type="hidden" name="action" value="restore">
        <input type="hidden" name="type" value="full">
        <input type="hidden" name="date" value="<?= htmlspecialchars($b['date']) ?>">
        <button type="submit">Restore Full Account</button>
      </form>
    </td>
  </tr>
  <?php endforeach; ?>
</table>

<h2>Database Backups</h2>
<table>
  <tr><th>Date</th><th>Database</th><th>Action</th></tr>
  <?php foreach ($backups as $b): foreach (($b['databases'] ?? []) as $db): ?>
  <tr>
    <td><?= htmlspecialchars($b['date']) ?></td>
    <td><?= htmlspecialchars($db) ?></td>
    <td>
      <form method="post" onsubmit="return confirm('This will overwrite the current <?= htmlspecialchars($db) ?> database with the backup from <?= htmlspecialchars($b['date']) ?>. Continue?');">
        <input type="hidden" name="action" value="restore">
        <input type="hidden" name="type" value="database">
        <input type="hidden" name="date" value="<?= htmlspecialchars($b['date']) ?>">
        <input type="hidden" name="db" value="<?= htmlspecialchars($db) ?>">
        <button type="submit">Restore Database</button>
      </form>
    </td>
  </tr>
  <?php endforeach; endforeach; ?>
</table>

<?php endif; ?>
</body>
</html>
