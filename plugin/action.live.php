<?php
/**
 * AJAX endpoint: queues a restore request for the logged-in cPanel user.
 * Returns JSON { ok: true, id: "..." } or { ok: false, error: "..." }.
 */
require_once __DIR__ . '/liveapi.php';
require_once __DIR__ . '/manifest.php';

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

$queueDir = SKY_SPOOL_DIR . '/restore-requests';

// The page posts form-encoded, which is what $_POST is filled from. A JSON
// body is still accepted so a page cached from an earlier version keeps
// working until the browser picks up the new one.
$input = $_POST;
if (!$input) {
    $input = json_decode((string) file_get_contents('php://input'), true) ?: [];
}
$requested = $input['type'] ?? '';
$type = in_array($requested, ['database', 'download'], true) ? $requested : 'full';
$date = preg_replace('/[^0-9\-]/', '', $input['date'] ?? '');
$db   = preg_replace('/[^a-zA-Z0-9_]/', '', $input['db'] ?? '');

// Hiding the buttons isn't enough — this is the boundary a crafted POST
// would come through. bin/restore-worker.sh checks the same flag again.
// A download only reads the backup, so it isn't gated by that flag.
if ($type !== 'download' && !sky_restore_enabled()) {
    http_response_code(403);
    echo json_encode(['ok' => false, 'error' => 'Self-service restore is disabled. Please contact support.']);
    exit;
}

[$backups, ] = sky_read_manifest($user);

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

// The queue is a shared drop box (mode 1733), so every account can write
// into it. Create the request exclusively and lock it down before a byte
// goes in, or an account that guessed the filename could read whose
// account and which database somebody else is restoring. Root, which is
// what bin/restore-worker.sh runs as, reads it regardless of mode.
$path = "$queueDir/$id.json";
$fh = @fopen($path, 'x');
if ($fh === false) {
    echo json_encode(['ok' => false, 'error' => 'Could not queue the request. Please try again.']);
    exit;
}
@chmod($path, 0600);
fwrite($fh, json_encode($req));
fclose($fh);

echo json_encode(['ok' => true, 'id' => $id]);
