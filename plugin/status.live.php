<?php
/**
 * AJAX endpoint: polls the status of a restore request. Only returns a
 * status the logged-in user actually owns (checked against the "user"
 * field bin/restore-worker.sh writes into the status file).
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
