<?php
/**
 * AJAX endpoint: queues a restore request for the logged-in cPanel user.
 * Returns JSON { ok: true, id: "..." } or { ok: false, error: "..." }.
 */
require_once __DIR__ . '/liveapi.php';

// Connected before a byte is printed, and closed however this script
// exits — otherwise cPanel appends its LiveAPI complaint to the JSON.
$cpanel = liveapi_connect();
register_shutdown_function('liveapi_end', $cpanel);

header('Content-Type: application/json');

$user = getenv('REMOTE_USER');
if (!$user || !preg_match('/^[a-zA-Z0-9_]+$/', $user)) {
    http_response_code(403);
    echo json_encode(['ok' => false, 'error' => 'Unable to determine cPanel user.']);
    exit;
}

$manifestFile = "/var/spool/skyserver-backup/manifests/{$user}.json";
$queueDir     = "/var/spool/skyserver-backup/restore-requests";
$restoreMarker = "/var/spool/skyserver-backup/user-restore-enabled";

$input = json_decode(file_get_contents('php://input'), true) ?: [];
$requested = $input['type'] ?? '';
$type = in_array($requested, ['database', 'download'], true) ? $requested : 'full';
$date = preg_replace('/[^0-9\-]/', '', $input['date'] ?? '');
$db   = preg_replace('/[^a-zA-Z0-9_]/', '', $input['db'] ?? '');

// Hiding the buttons isn't enough — this is the boundary a crafted POST
// would come through. bin/restore-worker.sh checks the same flag again.
// A download only reads the backup, so it isn't gated by that flag.
if ($type !== 'download' && !file_exists($restoreMarker)) {
    http_response_code(403);
    echo json_encode(['ok' => false, 'error' => 'Self-service restore is disabled. Please contact support.']);
    exit;
}

$backups = [];
if (is_readable($manifestFile)) {
    $backups = json_decode(file_get_contents($manifestFile), true) ?: [];
}

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

if (!$validDate || !$validDb) {
    echo json_encode(['ok' => false, 'error' => 'Invalid backup selection.']);
    exit;
}

if (!is_dir($queueDir) || !is_writable($queueDir)) {
    echo json_encode(['ok' => false, 'error' => 'Restore queue is unavailable. Contact support.']);
    exit;
}

$id = uniqid('req_', true);
$req = ['id' => $id, 'user' => $user, 'type' => $type, 'date' => $date];
if ($type === 'database') {
    $req['db'] = $db;
}
file_put_contents("$queueDir/$id.json", json_encode($req));

echo json_encode(['ok' => true, 'id' => $id]);
