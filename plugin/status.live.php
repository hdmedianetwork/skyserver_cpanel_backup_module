<?php
/**
 * Read-only JSON for the cPanel end-user page.
 *
 *   ?id=req_...   the status of one restore/download request, which only
 *                 its owner can see (checked against the "user" field
 *                 bin/restore-worker.sh writes into the status file)
 *   ?api=state    this account's backups, for the page's Refresh and for
 *                 the first paint after a request completes
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

if (($_GET['api'] ?? '') === 'state') {
    echo json_encode(['ok' => true, 'state' => sky_user_state($user)], JSON_UNESCAPED_SLASHES);
    exit;
}

$id = $_GET['id'] ?? '';
if (!preg_match('/^req_[a-zA-Z0-9.]+$/', $id)) {
    echo json_encode(['ok' => false, 'error' => 'Invalid request id.']);
    exit;
}

$statusFile = SKY_SPOOL_DIR . "/restore-status/{$id}.json";
if (!is_readable($statusFile)) {
    // Not picked up by the worker yet (runs once a minute).
    echo json_encode(['ok' => true, 'status' => 'queued']);
    exit;
}

$data = json_decode(file_get_contents($statusFile), true) ?: [];
if (($data['user'] ?? null) !== $user) {
    http_response_code(403);
    echo json_encode(['ok' => false, 'error' => 'Not your request.']);
    exit;
}

echo json_encode([
    'ok' => true,
    'status' => $data['status'] ?? 'unknown',
    'error' => $data['error'] ?? null,
    'download_url' => $data['download_url'] ?? null,
]);
