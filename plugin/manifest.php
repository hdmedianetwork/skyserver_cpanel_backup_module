<?php
/**
 * Finding and reading the manifest bin/backup-user.sh writes for an account.
 *
 * These pages run as the logged-in cPanel account, not as root, so every
 * directory down to /var/spool/skyserver-backup/manifests has to be
 * traversable by that account. When it isn't, the page renders exactly like
 * an account that has never been backed up — which is the one thing it must
 * not do, since the backups are running fine and only the view of them is
 * broken. So the two cases are told apart here, and a second copy of the
 * manifest inside the account's own home is used as a fallback for servers
 * that don't expose /var/spool to the account at all.
 */

const SKY_SPOOL_DIR = '/var/spool/skyserver-backup';
const SKY_MANIFEST_DIR = SKY_SPOOL_DIR . '/manifests';

function sky_home_dir(string $user): ?string {
    if (function_exists('posix_getpwnam')) {
        $info = @posix_getpwnam($user);
        if (is_array($info) && !empty($info['dir'])) {
            return rtrim($info['dir'], '/');
        }
    }
    // cpsrvd runs these pages with the account's own HOME, so this covers
    // a PHP build without the posix extension.
    $home = getenv('HOME');
    return $home ? rtrim($home, '/') : null;
}

/** Every place this account's manifest may be, best copy first. */
function sky_manifest_paths(string $user): array {
    $paths = [SKY_MANIFEST_DIR . "/{$user}.json"];
    $home = sky_home_dir($user);
    if ($home !== null) {
        $paths[] = "$home/.skyserver-backup/manifest.json";
    }
    return $paths;
}

/**
 * Returns [list-of-backups, visible]. "visible" is false only when no copy
 * of the manifest could be read AND the directory it would live in can't be
 * reached — that is, the account may well have backups this page cannot see,
 * so the caller must not claim there are none.
 */
function sky_read_manifest(string $user): array {
    foreach (sky_manifest_paths($user) as $path) {
        if (!is_readable($path)) {
            continue;
        }
        $raw = @file_get_contents($path);
        if ($raw === false) {
            continue;
        }
        $data = json_decode($raw, true);
        if (is_array($data)) {
            return [$data, true];
        }
    }
    // No manifest is the normal state before the first backup runs — but
    // only if we can actually see into the directory it belongs in.
    return [[], is_dir(SKY_MANIFEST_DIR)];
}

function sky_restore_enabled(): bool {
    return file_exists(SKY_SPOOL_DIR . '/user-restore-enabled');
}

/**
 * The stage a backup of this account has reached, or null when none is
 * running. bin/backup-user.sh writes this while it works and removes it on
 * the way out, however it exits.
 */
function sky_backup_progress(string $user): ?array {
    $f = SKY_SPOOL_DIR . "/progress/{$user}.json";
    if (!is_readable($f)) {
        return null;
    }
    $data = json_decode((string) @file_get_contents($f), true);
    if (!is_array($data) || !isset($data['message'])) {
        return null;
    }
    // A run that was killed without its trap firing would otherwise leave
    // the page claiming a backup is in progress forever.
    $age = time() - (int) @filemtime($f);
    if ($age > 900) {
        return null;
    }
    return $data;
}

/**
 * Everything the end-user page shows, in the shape its JavaScript renders
 * from — so the first paint and every later refresh come from one place.
 */
function sky_user_state(string $user): array {
    [$backups, $visible] = sky_read_manifest($user);
    $latest = $backups[0] ?? null;

    $bytes = 0;
    $dbNames = [];
    foreach ($backups as $b) {
        $bytes += (int) ($b['full_size_bytes'] ?? 0);
        foreach (($b['databases'] ?? []) as $db) {
            $dbNames[$db] = true;
        }
    }

    return [
        'user'           => $user,
        'backups'        => array_values($backups),
        'visible'        => $visible,
        'restoreEnabled' => sky_restore_enabled(),
        'backupRunning'  => sky_backup_progress($user),
        'totals'         => [
            'count'     => count($backups),
            'bytes'     => $bytes,
            'databases' => count($dbNames),
            'lastDate'  => $latest['date'] ?? null,
            'lastSize'  => $latest['full_size'] ?? null,
        ],
    ];
}
