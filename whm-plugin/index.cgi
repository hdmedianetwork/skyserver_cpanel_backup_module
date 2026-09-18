#!__PHP_BIN__
<?php
/**
 * SkyServer Backup Manager — WHM admin dashboard (root only, served by
 * WHM/cpsrvd as a CGI script via AppConfig).
 *
 * The page is a shell: PHP renders the chrome once and hands the browser a
 * snapshot of the state, and everything after that — every button, every
 * refresh, every poll — goes through the JSON API in this same file
 * (`index.cgi?api=<action>`). Nothing reloads the page, so a running
 * backup, a restore queue draining, and the log tail all stay live in
 * front of the admin.
 *
 * The shebang above is rewritten by bin/deploy.sh to the real PHP binary
 * path on this server.
 */

// cpsrvd serves this file as a CGI and reads the response headers straight
// off its stdout — but the shebang points at the PHP *CLI* binary, which
// emits none of its own. Same reason the CLI binary never fills $_GET or
// $_POST: cpsrvd passes the request in the environment and the body on
// stdin, which CLI leaves unread. Both are handled here, and the request
// has to be parsed *before* the header block, because which content type
// we send depends on whether this is an API call or the page itself.
if (PHP_SAPI === 'cli') {
    parse_str((string) ($_SERVER['QUERY_STRING'] ?? ''), $_GET);

    if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST'
        && stripos((string) ($_SERVER['CONTENT_TYPE'] ?? ''), 'application/x-www-form-urlencoded') !== false) {
        // Bounded by CONTENT_LENGTH: reading stdin to EOF can block until the
        // client closes the connection.
        $len  = (int) ($_SERVER['CONTENT_LENGTH'] ?? 0);
        $body = '';
        while (strlen($body) < $len && !feof(STDIN)) {
            $chunk = fread(STDIN, $len - strlen($body));
            if ($chunk === false || $chunk === '') {
                break;
            }
            $body .= $chunk;
        }
        parse_str($body, $_POST);
    }

    $_REQUEST = $_POST + $_GET;
}

$apiAction = (string) ($_GET['api'] ?? '');
$isApi     = $apiAction !== '';
$contentType = $isApi ? 'application/json; charset=utf-8' : 'text/html; charset=utf-8';

if (PHP_SAPI === 'cli') {
    echo "Content-type: $contentType\r\n\r\n";
} elseif (!headers_sent()) {
    header("Content-Type: $contentType");
}

const CONF_FILE     = '/etc/skyserver-backup.conf';
const LOG_FILE       = '/var/log/skyserver-backup.log';
const MANIFEST_DIR   = '/var/spool/skyserver-backup/manifests';
const STATUS_DIR      = '/var/spool/skyserver-backup/restore-status';
const INSTALL_DIR    = '/opt/skyserver-backup-module';
const LOCK_FILE       = '/var/spool/skyserver-backup/backup.lock';
const USER_RESTORE_MARKER = '/var/spool/skyserver-backup/user-restore-enabled';
const QUEUE_DIR       = '/var/spool/skyserver-backup/restore-requests';
const LOGO_URL        = 'https://ik.imagekit.io/hdmn/skybackupmanager.png';

// The stylesheet and the shared front-end runtime, which the end-user
// plugin uses too. bin/deploy.sh drops a copy next to each of them.
require_once __DIR__ . '/sky-ui.php';

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

/**
 * The config minus its secrets. The browser gets this, so the AWS keys
 * must never be in it — the form shows blank password fields and only
 * sends a key when the admin types a new one.
 */
function public_conf(array $conf): array {
    $keys = ['S3_BUCKET', 'AWS_DEFAULT_REGION', 'S3_ENDPOINT_URL', 'S3_ADDRESSING_STYLE',
             'RETENTION_DAYS', 'ALERT_EMAIL', 'BACKUP_WORK_DIR', 'DISK_SAFETY_MARGIN_MB',
             'ENABLE_USER_RESTORE'];
    $out = [];
    foreach ($keys as $k) {
        $out[$k] = (string) ($conf[$k] ?? '');
    }
    // Whether the credentials are set is worth showing; their value is not.
    $out['HAS_CREDENTIALS'] = (($conf['AWS_ACCESS_KEY_ID'] ?? '') !== ''
        && ($conf['AWS_ACCESS_KEY_ID'] ?? '') !== 'REPLACE_ME'
        && ($conf['AWS_SECRET_ACCESS_KEY'] ?? '') !== ''
        && ($conf['AWS_SECRET_ACCESS_KEY'] ?? '') !== 'REPLACE_ME');
    return $out;
}

function whm_accounts(): array {
    $out = shell_exec('whmapi1 listaccts --output=jsonpretty 2>/dev/null');
    preg_match_all('/"user"\s*:\s*"([^"]+)"/', $out ?? '', $m);
    return $m[1] ?? [];
}

function latest_run_summary(): array {
    if (!is_readable(LOG_FILE)) {
        return ['ok' => 0, 'fail' => 0, 'attempted' => 0, 'aborted' => false, 'abort_at' => null,
                'reasons' => [], 'started' => null, 'finished' => null, 'failed_users' => []];
    }
    $content = file_get_contents(LOG_FILE);
    $chunks = preg_split('/(?====== Backup run started)/', $content);
    $last = end($chunks) ?: '';
    preg_match('/Backup run started: (.+?) =====/', $last, $s);
    preg_match('/Backup run finished: (.+?) =====/', $last, $f);
    preg_match('/Backup run aborted: (.+?) =====/', $last, $a);

    $ok   = substr_count($last, '[OK]');
    $fail = substr_count($last, '[FAIL]');

    // The reason an aborted run wrote, so the dashboard can say what went
    // wrong instead of sending the admin to the log to find out.
    preg_match_all('/^\[!\] (.+)$/m', $last, $reasons);

    return [
        'ok'       => $ok,
        'fail'     => $fail,
        'attempted'=> $ok + $fail,
        'aborted'  => !empty($a),
        'abort_at' => $a[1] ?? null,
        'reasons'  => array_slice($reasons[1] ?? [], 0, 4),
        'started'  => $s[1] ?? null,
        'finished' => $f[1] ?? null,
        'failed_users' => array_values(array_filter(array_map(function ($l) {
            return preg_match('/\[FAIL\] (\S+)/', $l, $mm) ? $mm[1] : null;
        }, explode("\n", $last)))),
    ];
}

function account_backups(string $user): array {
    $user = preg_replace('/[^a-zA-Z0-9_]/', '', $user);
    $f = MANIFEST_DIR . "/$user.json";
    return is_readable($f) ? (json_decode(file_get_contents($f), true) ?: []) : [];
}

function account_rows(): array {
    $rows = [];
    foreach (whm_accounts() as $user) {
        $data = account_backups($user);
        $latest = $data[0] ?? null;
        $rows[] = [
            'user' => $user,
            'last_date' => $latest['date'] ?? null,
            'last_size' => $latest['full_size'] ?? null,
            'last_bytes' => $latest['full_size_bytes'] ?? 0,
            'db_count' => $latest ? count($latest['databases'] ?? []) : 0,
            'total_backups' => count($data),
            'backups' => $data,
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

function backup_log_tail(int $lines = 200): string {
    if (!is_readable(LOG_FILE)) return '(no log yet)';
    $out = shell_exec('tail -n ' . (int) $lines . ' ' . escapeshellarg(LOG_FILE) . ' 2>/dev/null');
    return $out !== null && $out !== '' ? $out : '(log is empty)';
}

function restore_jobs(int $limit = 25): array {
    $files = glob(STATUS_DIR . '/*.json') ?: [];
    usort($files, fn($a, $b) => filemtime($b) <=> filemtime($a));
    $jobs = [];
    foreach (array_slice($files, 0, $limit) as $f) {
        $data = json_decode((string) file_get_contents($f), true) ?: [];
        $data['file_time'] = filemtime($f);
        $jobs[] = $data;
    }
    return $jobs;
}

/**
 * Turns self-update.sh's raw output into something worth looking at.
 *
 * What it prints is a git fetch, then deploy.sh's own running commentary,
 * then one line naming the new version — dumping all of it into a black
 * box told the admin nothing and looked like an error even on success. The
 * deploy steps become a checklist, the version becomes the headline, and
 * the raw text stays available behind a toggle for when something breaks.
 */
function parse_deploy_output(string $raw): array {
    $steps = [];
    $version = null;
    foreach (explode("\n", $raw) as $line) {
        $line = rtrim($line);
        if (trim($line) === '') continue;

        if (preg_match('/^\[skyserver-backup\] (.*)$/', $line, $m)) {
            $text = trim($m[1]);
            $level = 'ok';
            if (stripos($text, 'WARNING') !== false) $level = 'warn';
            if (stripos($text, 'ERROR') !== false)   $level = 'error';
            $steps[] = [
                'text'  => rtrim($text, '.'),
                'sub'   => str_starts_with($m[1], '  '),
                'level' => $level,
            ];
        } elseif (preg_match('/^Updated to version (\S+?)\.?$/', $line, $m)) {
            $version = $m[1];
        }
    }
    return ['steps' => $steps, 'version' => $version, 'raw' => $raw];
}

function dashboard_state(): array {
    $conf = read_conf();
    $rows = account_rows();
    $summary = latest_run_summary();

    $protectedCount = 0;
    $unprotected = [];
    foreach ($rows as $r) {
        if ($r['last_date']) {
            $protectedCount++;
        } else {
            $unprotected[] = $r['user'];
        }
    }

    $totalBytes = 0;
    foreach ($rows as $r) {
        foreach ($r['backups'] as $b) {
            $totalBytes += (int) ($b['full_size_bytes'] ?? 0);
        }
    }

    return [
        'version'      => trim((string) @file_get_contents(INSTALL_DIR . '/VERSION')) ?: 'unknown',
        'running'      => is_backup_running(),
        'accounts'     => $rows,
        'jobs'         => restore_jobs(),
        'config'       => public_conf($conf),
        'summary'      => $summary,
        'totals'       => [
            'accounts'    => count($rows),
            'protected'   => $protectedCount,
            'unprotected' => $unprotected,
            'bytes'       => $totalBytes,
        ],
        'configured'   => ($conf['S3_BUCKET'] ?? '') !== '' && ($conf['S3_BUCKET'] ?? '') !== 'your-bucket-name',
        'server_time'  => date('c'),
    ];
}

function json_out(array $payload): void {
    echo json_encode($payload, JSON_UNESCAPED_SLASHES);
    exit;
}

// ---------------------------------------------------------------------------
// JSON API. Every button on the page lands here; nothing reloads.
// ---------------------------------------------------------------------------
if ($isApi) {
    $isPost = ($_SERVER['REQUEST_METHOD'] ?? '') === 'POST';

    // Anything that changes the server is POST-only, so a stray GET — a
    // prefetch, a bookmarked URL, an image tag on another page — can never
    // kick off a backup or a restore.
    $mutating = ['run_now', 'backup_user', 'admin_restore', 'save_config',
                 'test_s3', 'update_apply'];
    if (in_array($apiAction, $mutating, true) && !$isPost) {
        http_response_code(405);
        json_out(['ok' => false, 'error' => 'This action requires POST.']);
    }

    switch ($apiAction) {

        case 'state':
            json_out(['ok' => true, 'state' => dashboard_state()]);

        case 'log':
            json_out(['ok' => true, 'log' => backup_log_tail(200), 'running' => is_backup_running()]);

        case 'run_now':
            if (is_backup_running()) {
                json_out(['ok' => false, 'error' => 'A backup run is already in progress.']);
            }
            shell_exec('nohup ' . escapeshellarg(INSTALL_DIR . '/bin/backup-all.sh') . ' > /dev/null 2>&1 &');
            json_out(['ok' => true, 'message' => 'Backup run started — this page will follow along.']);

        case 'backup_user':
            $target = preg_replace('/[^a-zA-Z0-9_]/', '', $_POST['user'] ?? '');
            if ($target === '' || !in_array($target, whm_accounts(), true)) {
                json_out(['ok' => false, 'error' => 'Unknown account.']);
            }
            if (is_backup_running()) {
                json_out(['ok' => false, 'error' => 'A backup run is already in progress — try again once it finishes.']);
            }
            shell_exec('nohup ' . escapeshellarg(INSTALL_DIR . '/bin/backup-user.sh') . ' '
                . escapeshellarg($target) . ' >> ' . escapeshellarg(LOG_FILE) . ' 2>&1 &');
            json_out(['ok' => true, 'message' => "Backing up $target — watch the log for progress."]);

        case 'admin_restore':
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
                json_out(['ok' => false, 'error' => 'That backup does not exist for that account.']);
            }

            // Queued with source=admin so restore-worker.sh runs it even
            // while user self-restore is switched off.
            $id  = uniqid('req_', true);
            $req = ['id' => $id, 'user' => $target, 'type' => $type, 'date' => $date, 'source' => 'admin'];
            if ($type === 'database') $req['db'] = $db;

            // Same drop box the cPanel plugin writes into, so the request is
            // locked to root before anything goes in it.
            $path = QUEUE_DIR . "/$id.json";
            $fh = @fopen($path, 'x');
            if ($fh === false) {
                json_out(['ok' => false, 'error' => 'Could not queue the restore. Is the spool directory present?']);
            }
            @chmod($path, 0600);
            fwrite($fh, json_encode($req));
            fclose($fh);

            $what = $type === 'full' ? 'full account' : "database $db";
            json_out(['ok' => true, 'id' => $id,
                      'message' => "Restore of $what for $target queued — it starts within a minute."]);

        case 'save_config':
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
            if (!empty($_POST['aws_key']))    $updates['AWS_ACCESS_KEY_ID'] = $_POST['aws_key'];
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
            json_out(['ok' => true, 'message' => 'Configuration saved.', 'state' => dashboard_state()]);

        case 'test_s3':
            // bin/s3-test.sh reads the same config the backup jobs do, so the
            // test exercises exactly the path a real run takes — including the
            // custom endpoint for S3-compatible providers.
            $out = trim((string) shell_exec(escapeshellarg(INSTALL_DIR . '/bin/s3-test.sh') . ' 2>&1'));
            $passed = str_contains($out, 'All checks passed');
            json_out(['ok' => true, 'passed' => $passed, 'output' => $out,
                      'message' => $passed ? 'S3 connection is healthy.' : 'S3 test reported a problem.']);

        case 'update_check':
            $out = trim((string) shell_exec(escapeshellarg(INSTALL_DIR . '/bin/self-update.sh') . ' check 2>&1'));
            if (str_ends_with($out, 'update')) {
                preg_match('/local (\S+) remote (\S+)/', $out, $m);
                json_out(['ok' => true, 'available' => true, 'local' => $m[1] ?? '?', 'remote' => $m[2] ?? '?',
                          'message' => "Version {$m[2]} is available — you are on {$m[1]}."]);
            }
            if (str_ends_with($out, 'current')) {
                preg_match('/local (\S+)/', $out, $m);
                json_out(['ok' => true, 'available' => false, 'local' => $m[1] ?? '?',
                          'message' => "You are up to date (v{$m[1]})."]);
            }
            json_out(['ok' => false, 'error' => 'Could not reach GitHub to check for updates.']);

        case 'update_apply':
            $raw = (string) shell_exec(escapeshellarg(INSTALL_DIR . '/bin/self-update.sh') . ' apply 2>&1');
            $parsed = parse_deploy_output(trim($raw));
            $done = $parsed['version'] !== null;
            json_out([
                'ok' => $done,
                'result' => $parsed,
                'message' => $done ? "Updated to v{$parsed['version']}." : 'Update failed.',
                'state' => $done ? dashboard_state() : null,
            ]);
    }

    http_response_code(404);
    json_out(['ok' => false, 'error' => 'Unknown action.']);
}

// ---------------------------------------------------------------------------
// The page itself: chrome plus one snapshot of the state, so the first
// paint has real data in it and the JS renders from a single code path.
// ---------------------------------------------------------------------------
$initialState = dashboard_state();
$initialLog   = backup_log_tail(200);

$SKY_STYLES = sky_styles();

// Buffer the page body so it can be dropped either into WHM's own chrome
// or into a standalone document, without writing the markup twice.
ob_start();
?>
<div class="wrap">

  <div class="mast">
    <img src="<?= LOGO_URL ?>" alt="SkyServer Backup Manager">
    <div class="titles">
      <h1>Backup Manager</h1>
      <div class="sub">
        S3 backups across every cPanel account on this server
        <span class="vpill" id="sky-version">v<?= htmlspecialchars($initialState['version']) ?></span>
      </div>
    </div>
    <div class="spacer"></div>
    <div class="tools">
      <button class="btn btn-icon" id="sky-theme" title="Switch between light and dark" aria-label="Switch theme"></button>
      <button class="btn" id="sky-refresh" data-icon="refresh">Refresh</button>
      <button class="btn" id="sky-update-check" data-icon="download">Check for Updates</button>
    </div>
  </div>

  <div id="sky-banner"></div>
  <div class="tiles" id="sky-tiles"></div>

  <div class="tabs" role="tablist" id="sky-tabs">
    <button class="tab" role="tab" data-tab="overview" data-icon="grid" aria-selected="true">Overview</button>
    <button class="tab" role="tab" data-tab="accounts" data-icon="users" aria-selected="false">Accounts <span class="count" id="c-accounts">0</span></button>
    <button class="tab" role="tab" data-tab="restores" data-icon="rotate" aria-selected="false">Restores <span class="count" id="c-jobs">0</span></button>
    <button class="tab" role="tab" data-tab="settings" data-icon="sliders" aria-selected="false">Settings</button>
    <button class="tab" role="tab" data-tab="logs" data-icon="terminal" aria-selected="false">Activity Log</button>
  </div>

  <div class="panel" id="p-overview"></div>
  <div class="panel" id="p-accounts" hidden></div>
  <div class="panel" id="p-restores" hidden></div>
  <div class="panel" id="p-settings" hidden></div>
  <div class="panel" id="p-logs" hidden></div>

  <noscript>
    <div class="note note-warn" style="margin-top:16px">
      This dashboard needs JavaScript. WHM itself requires it too, so enabling it for this
      browser will bring both back.
    </div>
  </noscript>
</div>

<div class="sky-toasts" id="sky-toasts"></div>

<?= sky_runtime_js() ?>
<script>
(function () {
  "use strict";

  var STATE = <?= json_encode($initialState, JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_UNESCAPED_SLASHES) ?>;
  var LOG   = <?= json_encode($initialLog, JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_UNESCAPED_SLASHES) ?>;

  var $        = function (id) { return document.getElementById(id); };
  var pollTimer = null;
  var accountFilter = '';
  var updateInfo = null;

  // The shared runtime (icons, toasts, the modal, the JSON helper, the
  // theme) comes from sky-ui.php, which the cPanel end-user page uses too.
  // Aliased locally so the rest of this file reads the same either way.
  var UI = window.SkyUI;
  var svg = UI.svg, esc = UI.esc, bytes = UI.bytes, ago = UI.ago,
      daysSince = UI.daysSince, initials = UI.initials, toast = UI.toast,
      modal = UI.modal, withBusy = UI.withBusy, paintIcons = UI.paintIcons,
      emptyState = UI.emptyState;

  /** Every call goes to this same CGI, which answers JSON for ?api=<action>. */
  function api(action, data) {
    return UI.api('index.cgi?api=' + encodeURIComponent(action), data);
  }

  // ------------------------------------------------------------- renders
  function tile(cls, iconName, key, value, note) {
    return '<div class="tile ' + cls + '"><div class="ico">' + svg(iconName) + '</div>' +
           '<div><div class="k">' + esc(key) + '</div><div class="v">' + value + '</div>' +
           (note ? '<div class="meta">' + note + '</div>' : '') + '</div></div>';
  }

  function renderTiles() {
    var t = STATE.totals, s = STATE.summary, c = STATE.config;
    var pct = t.accounts ? Math.round(t.protected / t.accounts * 100) : 0;
    var unprotected = t.unprotected.length;
    var restoreOn = c.ENABLE_USER_RESTORE === '1';

    $('sky-tiles').innerHTML =
      tile(unprotected ? 'warn' : 'ok', 'shield', 'Accounts protected',
           t.protected + '<span class="dim" style="font-size:15px;font-weight:500"> / ' + t.accounts + '</span>',
           '<div class="bar"><i style="width:' + pct + '%;background:' +
             (unprotected ? 'var(--warn)' : 'var(--ok)') + '"></i></div>') +
      tile((s.aborted || (!s.attempted && !STATE.running && s.started)) ? 'bad' : (s.fail ? 'bad' : 'ok'),
           (s.aborted || s.fail || (!s.attempted && s.started && !STATE.running)) ? 'alert' : 'checkc',
           'Last run',
           s.aborted ? 'aborted' : (s.ok + ' ok' + (s.fail ? ' · ' + s.fail + ' failed' : '')),
           esc(s.aborted ? 'stopped ' + (s.abort_at || '')
               : (s.finished ? 'finished ' + s.finished
                  : (s.started ? 'started ' + s.started : 'never run')))) +
      tile('', 'cloud', 'Stored in S3', bytes(t.bytes),
           'across all accounts and dates') +
      tile('', 'clock', 'Retention', esc(c.RETENTION_DAYS || '—') + '<span class="dim" style="font-size:14px;font-weight:500"> days</span>',
           'older backups are deleted nightly') +
      tile(restoreOn ? 'warn' : '', 'key', 'User self-restore',
           '<span class="pill ' + (restoreOn ? 'pill-warn' : 'pill-none') + '" style="font-size:12px">' +
             (restoreOn ? 'enabled' : 'disabled') + '</span>',
           restoreOn ? 'customers can overwrite their own data' : 'only you can restore');

    $('c-accounts').textContent = t.accounts;
    $('c-jobs').textContent = STATE.jobs.length;
  }

  function renderBanner() {
    var out = '';
    if (STATE.running) {
      out += '<div class="note note-ok" style="margin-bottom:14px">' + svg('zap') +
             '<div><b>A backup run is in progress.</b> This page is following it live — ' +
             'the accounts table and the log below update on their own.</div></div>';
    }
    if (!STATE.configured) {
      out += '<div class="note note-warn" style="margin-bottom:14px">' + svg('alert') +
             '<div><b>No S3 bucket is configured yet.</b> Nothing is being backed up. ' +
             'Open <a href="#" data-goto="settings">Settings</a> to set the bucket, region and credentials, ' +
             'then run the connection test.</div></div>';
    } else if (!STATE.config.HAS_CREDENTIALS) {
      out += '<div class="note note-warn" style="margin-bottom:14px">' + svg('key') +
             '<div><b>S3 credentials are still placeholders.</b> Backups will fail until real keys are saved in ' +
             '<a href="#" data-goto="settings">Settings</a>.</div></div>';
    }
    if (updateInfo && updateInfo.available) {
      out += '<div class="note note-ok" style="margin-bottom:14px">' + svg('download') +
             '<div><b>Version ' + esc(updateInfo.remote) + ' is available.</b> ' +
             'This server runs ' + esc(updateInfo.local) + '. Your config and existing backups are not touched.</div>' +
             '<button class="btn btn-primary btn-sm" id="sky-update-apply" style="margin-left:auto">Install update</button></div>';
    }
    $('sky-banner').innerHTML = out;
  }

  function renderOverview() {
    var s = STATE.summary, t = STATE.totals, c = STATE.config;

    var checks = [
      { ok: STATE.configured, good: 'S3 bucket configured (' + esc(c.S3_BUCKET || '') + ')', bad: 'No S3 bucket set' },
      { ok: !!c.HAS_CREDENTIALS, good: 'S3 credentials saved', bad: 'S3 credentials are missing or placeholders' },
      { ok: t.accounts > 0, good: t.accounts + ' cPanel account' + (t.accounts === 1 ? '' : 's') + ' discovered', bad: 'No cPanel accounts found via whmapi1' },
      { ok: t.unprotected.length === 0, good: 'Every account has at least one backup',
        bad: t.unprotected.length + ' account' + (t.unprotected.length === 1 ? ' has' : 's have') +
             ' no backup yet: ' + esc(t.unprotected.slice(0, 6).join(', ')) +
             (t.unprotected.length > 6 ? ' and ' + (t.unprotected.length - 6) + ' more' : '') },
      { ok: !s.aborted && s.attempted > 0 && s.fail === 0,
        good: 'Last run finished with no failures',
        bad: s.aborted
          ? 'The last run stopped before backing up anything' +
            (s.reasons && s.reasons.length ? ' — ' + esc(s.reasons[0]) : '') +
            '. Nothing was backed up. <a href="#" data-goto="logs">Open the Activity Log</a>.'
          : (s.attempted === 0
              ? (STATE.running
                  ? 'A run is in progress and has not finished an account yet'
                  : 'The last run never reported finishing, and backed up no accounts. ' +
                    '<a href="#" data-goto="logs">Open the Activity Log</a>.')
              : s.fail + ' account' + (s.fail === 1 ? '' : 's') +
                ' failed in the last run: ' + esc((s.failed_users || []).join(', '))) }
    ];

    var checkHtml = checks.map(function (k) {
      return '<li class="' + (k.ok ? '' : 'warn') + '">' + svg(k.ok ? 'checkc' : 'alert') +
             '<span>' + (k.ok ? k.good : k.bad) + '</span></li>';
    }).join('');

    var recent = STATE.jobs.slice(0, 5);

    $('p-overview').innerHTML =
      '<div class="card">' +
        '<header><div class="grow"><h2>Backup runs</h2>' +
          '<div class="hint">Daily at 02:00 by cron, or on demand from here.</div></div>' +
          (STATE.running
            ? '<span class="pill pill-info pill-live">running now</span>'
            : '<button class="btn btn-primary" data-act="run-now" data-icon="play">Run backup now</button>') +
        '</header>' +
        '<div class="body">' +
          '<dl class="kv">' +
            '<dt>Last started</dt><dd>' + esc(s.started || 'never') + '</dd>' +
            '<dt>Last finished</dt><dd>' +
              esc(s.aborted ? 'aborted ' + (s.abort_at || '')
                  : (s.finished || (STATE.running ? 'still running' : '—'))) + '</dd>' +
            '<dt>Result</dt><dd>' +
              (s.aborted
                ? '<span class="pill pill-bad">stopped before backing up anything</span>'
                : '<span class="pill ' + (s.ok ? 'pill-ok' : 'pill-none') + '">' + s.ok + ' succeeded</span> ' +
                  (s.fail ? '<span class="pill pill-bad">' + s.fail + ' failed</span>' : '')) +
            '</dd>' +
            (s.aborted && s.reasons && s.reasons.length
              ? '<dt>Reason</dt><dd class="mono" style="font-weight:400">' +
                s.reasons.map(function (r) { return esc(r); }).join('<br>') + '</dd>'
              : '') +
          '</dl>' +
        '</div>' +
      '</div>' +

      '<div class="card">' +
        '<header><h2>Health</h2></header>' +
        '<div class="body"><ul class="steps">' + checkHtml + '</ul></div>' +
      '</div>' +

      '<div class="card">' +
        '<header><div class="grow"><h2>Recent restore jobs</h2></div>' +
          '<button class="btn btn-sm" data-goto="restores">View all</button></header>' +
        (recent.length ? '<div class="tbl-scroll">' + jobsTable(recent) + '</div>' : emptyState('inbox',
            'No restores yet', 'Restores queued from here or by a customer will show up in this list.')) +
      '</div>';
  }

  function jobsTable(jobs) {
    var cls = { success: 'pill-ok', failed: 'pill-bad', running: 'pill-info', queued: 'pill-warn' };
    return '<table><thead><tr><th>Account</th><th>Status</th><th>Updated</th><th>Detail</th></tr></thead><tbody>' +
      jobs.map(function (j) {
        var st = j.status || 'unknown';
        return '<tr>' +
          '<td><div class="who"><span class="avatar">' + esc(initials(j.user)) + '</span>' + esc(j.user || '—') + '</div></td>' +
          '<td><span class="pill ' + (cls[st] || 'pill-none') + (st === 'running' || st === 'queued' ? ' pill-live' : '') + '">' + esc(st) + '</span></td>' +
          '<td class="nowrap dim">' + esc(ago(j.updated_at)) + '</td>' +
          '<td class="dim">' + esc(j.error || (j.download_url ? 'download link issued' : '')) + '</td>' +
        '</tr>';
      }).join('') + '</tbody></table>';
  }

  function renderAccounts() {
    var rows = STATE.accounts.filter(function (r) {
      return !accountFilter || r.user.toLowerCase().indexOf(accountFilter) !== -1;
    });

    var body = rows.length ? '<div class="tbl-scroll"><table><thead><tr>' +
        '<th>Account</th><th>Last backup</th><th>Size</th><th>Databases</th><th>Kept</th><th>Status</th><th class="right">Actions</th>' +
      '</tr></thead><tbody>' +
      rows.map(function (r) {
        var d = daysSince(r.last_date);
        var pill = !r.last_date ? '<span class="pill pill-none">never</span>'
                 : d <= 1 ? '<span class="pill pill-ok">current</span>'
                 : d <= 3 ? '<span class="pill pill-warn">' + d + ' days old</span>'
                 : '<span class="pill pill-bad">' + d + ' days old</span>';
        return '<tr>' +
          '<td><div class="who"><span class="avatar">' + esc(initials(r.user)) + '</span><b>' + esc(r.user) + '</b></div></td>' +
          '<td class="nowrap mono">' + esc(r.last_date || '—') + '</td>' +
          '<td class="nowrap mono">' + esc(r.last_size || '—') + '</td>' +
          '<td>' + (r.db_count ? '<span class="chip">' + r.db_count + ' db</span>' : '<span class="dim">none</span>') + '</td>' +
          '<td class="mono">' + r.total_backups + '</td>' +
          '<td>' + pill + '</td>' +
          '<td class="right nowrap">' +
            '<button class="btn btn-sm" data-act="backup-user" data-user="' + esc(r.user) + '"' +
              (STATE.running ? ' disabled title="A backup run is already in progress"' : '') + '>Back up</button> ' +
            '<button class="btn btn-sm" data-act="restore" data-user="' + esc(r.user) + '"' +
              (r.total_backups ? '' : ' disabled title="No backup to restore"') + '>Restore</button>' +
          '</td>' +
        '</tr>';
      }).join('') + '</tbody></table></div>'
      : emptyState('users', accountFilter ? 'No account matches "' + accountFilter + '"' : 'No cPanel accounts found',
          accountFilter ? 'Clear the search to see them all.' : 'whmapi1 listaccts returned nothing on this server.');

    $('p-accounts').innerHTML =
      '<div class="card">' +
        '<header><div class="grow"><h2>Accounts</h2>' +
          '<div class="hint">Every cPanel account on this server and the state of its latest backup.</div></div>' +
          '<div class="field search" style="margin:0">' + svg('search') +
            '<input type="search" id="sky-acct-search" placeholder="Filter accounts…" value="' + esc(accountFilter) + '">' +
          '</div>' +
        '</header>' + body +
      '</div>';

    var box = $('sky-acct-search');
    if (box) {
      box.addEventListener('input', function () {
        accountFilter = box.value.trim().toLowerCase();
        renderAccounts();
        var again = $('sky-acct-search');
        again.focus();
        again.setSelectionRange(again.value.length, again.value.length);
      });
    }
  }

  function renderRestores() {
    $('p-restores').innerHTML =
      '<div class="card">' +
        '<header><div class="grow"><h2>Restore an account</h2>' +
          '<div class="hint">Runs as admin, so it works even while customer self-restore is switched off.</div></div>' +
          '<button class="btn btn-primary" data-act="restore" data-icon="rotate">New restore</button>' +
        '</header>' +
        '<div class="body"><div class="note">' + svg('info') +
          '<div>A restore overwrites the live account or database with the backup and <b>cannot be undone</b>. ' +
          'Test it on a throwaway account before enabling self-restore for customers.</div></div></div>' +
      '</div>' +
      '<div class="card">' +
        '<header><div class="grow"><h2>Restore jobs</h2>' +
          '<div class="hint">The queue is picked up by cron every minute.</div></div>' +
          '<button class="btn btn-sm" data-act="refresh" data-icon="refresh">Refresh</button></header>' +
        (STATE.jobs.length ? '<div class="tbl-scroll">' + jobsTable(STATE.jobs) + '</div>'
          : emptyState('inbox', 'No restore jobs yet', 'Anything you or a customer restores will be listed here.')) +
      '</div>';
  }

  function renderSettings() {
    var c = STATE.config;
    var on = c.ENABLE_USER_RESTORE === '1';
    function f(label, name, val, type, ph, help) {
      return '<div class="field"><label for="f-' + name + '">' + esc(label) + '</label>' +
        '<input id="f-' + name + '" name="' + name + '" type="' + (type || 'text') + '" ' +
        'value="' + esc(val || '') + '" placeholder="' + esc(ph || '') + '">' +
        (help ? '<div class="help">' + esc(help) + '</div>' : '') + '</div>';
    }

    $('p-settings').innerHTML =
      '<form id="sky-config">' +
      '<div class="card">' +
        '<header><div class="grow"><h2>Destination</h2>' +
          '<div class="hint">Where backups are uploaded. Works with Amazon S3 and any S3-compatible provider.</div></div>' +
          '<button type="button" class="btn btn-sm" data-act="test-s3" data-icon="zap">Test connection</button>' +
        '</header>' +
        '<div class="body"><div class="grid">' +
          f('S3 bucket', 's3_bucket', c.S3_BUCKET, 'text', 'my-backup-bucket') +
          f('Region', 'aws_region', c.AWS_DEFAULT_REGION, 'text', 'ap-south-1') +
          f('Endpoint URL', 's3_endpoint', c.S3_ENDPOINT_URL, 'text', 'https://s3.wasabisys.com',
            'Leave blank for Amazon S3. Set it for Wasabi, Backblaze B2, IDrive e2, DigitalOcean Spaces, MinIO, Contabo…') +
          '<div class="field"><label for="f-addressing_style">URL style</label>' +
            '<select id="f-addressing_style" name="addressing_style">' +
              '<option value="path"' + (c.S3_ADDRESSING_STYLE !== 'virtual' ? ' selected' : '') + '>Path — endpoint.com/bucket</option>' +
              '<option value="virtual"' + (c.S3_ADDRESSING_STYLE === 'virtual' ? ' selected' : '') + '>Virtual host — bucket.endpoint.com</option>' +
            '</select><div class="help">Only used with a custom endpoint. Path style is safe for bucket names containing a dot.</div></div>' +
          f('Access key ID', 'aws_key', '', 'password', c.HAS_CREDENTIALS ? '•••••••• (saved — leave blank to keep)' : 'AKIA…') +
          f('Secret access key', 'aws_secret', '', 'password', c.HAS_CREDENTIALS ? '•••••••• (saved — leave blank to keep)' : '') +
        '</div>' +
        '<div id="sky-s3-result"></div>' +
        '</div>' +
      '</div>' +

      '<div class="card">' +
        '<header><h2>Schedule &amp; storage</h2></header>' +
        '<div class="body"><div class="grid">' +
          f('Retention (days)', 'retention_days', c.RETENTION_DAYS || '7', 'number', '7',
            'Backups older than this are deleted from S3 after each nightly run.') +
          f('Alert email on failure', 'alert_email', c.ALERT_EMAIL, 'text', 'ops@example.com', 'Blank disables alerts.') +
          f('Staging directory', 'work_dir', c.BACKUP_WORK_DIR || '/root', 'text', '/root',
            'Where account tarballs are built before upload. Point it at a partition with room for your largest account.') +
          f('Disk safety margin (MB)', 'disk_margin', c.DISK_SAFETY_MARGIN_MB || '2048', 'number', '2048',
            'An account is skipped rather than filling the disk and taking every site down with it.') +
        '</div></div>' +
      '</div>' +

      '<div class="card">' +
        '<header><h2>Customer self-restore</h2></header>' +
        '<div class="body">' +
          '<div class="switch">' +
            '<div class="txt"><b>Let cPanel users restore their own backups</b>' +
              '<span>A restore overwrites their live data and cannot be undone. Verify one yourself first.</span></div>' +
            '<button type="button" class="toggle" id="sky-restore-toggle" role="switch" aria-checked="' + on + '"></button>' +
            '<input type="hidden" name="user_restore" id="f-user_restore" value="' + (on ? '1' : '0') + '">' +
          '</div>' +
        '</div>' +
      '</div>' +

      '<div class="row" style="justify-content:flex-end; margin-bottom:16px">' +
        '<span class="dim" style="font-size:12px" id="sky-save-hint"></span>' +
        '<button type="submit" class="btn btn-primary" data-icon="check">Save configuration</button>' +
      '</div>' +
      '</form>';

    var toggle = $('sky-restore-toggle');
    toggle.addEventListener('click', function () {
      var next = toggle.getAttribute('aria-checked') !== 'true';
      toggle.setAttribute('aria-checked', String(next));
      $('f-user_restore').value = next ? '1' : '0';
      $('sky-save-hint').textContent = 'Unsaved change';
    });
    $('sky-config').addEventListener('input', function () {
      $('sky-save-hint').textContent = 'Unsaved changes';
    });
    $('sky-config').addEventListener('submit', onSaveConfig);
    paintIcons($('p-settings'));
  }

  function colorLog(text) {
    return String(text).split('\n').map(function (line) {
      var cls = 'l-dim';
      if (/^=====/.test(line))              cls = 'l-hdr';
      else if (/^\[OK\]/.test(line))        cls = 'l-ok';
      else if (/^\[FAIL\]|^\[!\]/.test(line)) cls = 'l-bad';
      else if (/WARNING|warn/i.test(line))  cls = 'l-warn';
      else if (/^\[\*\]/.test(line))        cls = '';
      return '<span class="' + cls + '">' + esc(line) + '</span>';
    }).join('\n');
  }

  function renderLogs() {
    $('p-logs').innerHTML =
      '<div class="card">' +
        '<header><div class="grow"><h2>Activity log</h2>' +
          '<div class="hint">The last 200 lines of /var/log/skyserver-backup.log' +
            (STATE.running ? ' — refreshing every few seconds while a run is in progress.' : '.') + '</div></div>' +
          (STATE.running ? '<span class="pill pill-info pill-live">live</span> ' : '') +
          '<button class="btn btn-sm" data-act="refresh-log" data-icon="refresh">Refresh</button>' +
        '</header>' +
        '<pre class="console" id="sky-log">' + colorLog(LOG) + '</pre>' +
      '</div>';
    var pre = $('sky-log');
    pre.scrollTop = pre.scrollHeight;
    paintIcons($('p-logs'));
  }

  /** Fills every [data-icon] that hasn't been painted yet. */
  function paintIcons(scope) {
    (scope || document).querySelectorAll('[data-icon]').forEach(function (el) {
      if (el.dataset.painted) return;
      el.insertAdjacentHTML('afterbegin', svg(el.dataset.icon));
      el.dataset.painted = '1';
    });
  }

  function renderAll() {
    renderTiles();
    renderBanner();
    renderOverview();
    renderAccounts();
    renderRestores();
    renderSettings();
    renderLogs();
    paintIcons(document);
    syncPolling();
  }

  /** Everything except the settings form, which must not be redrawn under
      the admin while they are typing into it. */
  function renderDynamic() {
    renderTiles();
    renderBanner();
    renderOverview();
    if (!(document.activeElement && document.activeElement.id === 'sky-acct-search')) {
      renderAccounts();
    }
    renderRestores();
    paintIcons(document);
    syncPolling();
  }

  // ------------------------------------------------------------- polling
  function needsPoll() {
    if (STATE.running) return true;
    return STATE.jobs.some(function (j) { return j.status === 'queued' || j.status === 'running'; });
  }
  function syncPolling() {
    if (needsPoll() && !pollTimer) {
      pollTimer = setInterval(function () { refreshState(true); }, 5000);
    } else if (!needsPoll() && pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  }

  /**
   * @param quiet  Set by the poller. A poll that fails is not worth a toast
   *               every five seconds, but a refresh the admin clicked must
   *               say so — so only the poller swallows the error, and every
   *               other caller lets it reach withBusy().
   */
  function refreshState(quiet) {
    var wasRunning = STATE.running;
    return api('state').then(function (res) {
      if (!res.ok) throw new Error(res.error || 'The server could not report its state.');
      STATE = res.state;
      renderDynamic();
      // A run that has just finished is exactly when the admin wants the
      // log, so pull it in the same beat rather than on the next tick.
      if (wasRunning && !STATE.running) {
        toast('ok', 'Backup run finished — ' + STATE.summary.ok + ' succeeded' +
                    (STATE.summary.fail ? ', ' + STATE.summary.fail + ' failed' : '') + '.');
        refreshLog().catch(function () {});
      } else if (STATE.running) {
        refreshLog().catch(function () {});
      }
    }).catch(function (err) {
      if (!quiet) throw err;
      if (window.console) console.warn('[skyserver] state poll failed:', err.message);
    });
  }

  function refreshLog() {
    return api('log').then(function (res) {
      if (!res.ok) throw new Error(res.error || 'The server could not read the log.');
      LOG = res.log;
      var pre = $('sky-log');
      if (!pre) return;
      var atBottom = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 40;
      pre.innerHTML = colorLog(LOG);
      if (atBottom) pre.scrollTop = pre.scrollHeight;
    });
  }

  // ------------------------------------------------------------- actions
  function onSaveConfig(e) {
    e.preventDefault();
    var form = e.target;
    var btn  = form.querySelector('button[type="submit"]');
    var data = {};
    new FormData(form).forEach(function (v, k) { data[k] = v; });

    withBusy(btn, api('save_config', data)).then(function (res) {
      if (!res.ok) { toast('bad', res.error || 'Could not save.'); return; }
      STATE = res.state;
      toast('ok', res.message);
      renderAll();
      showTab('settings');
    }).catch(function () {});
  }

  function onTestS3(btn) {
    var out = $('sky-s3-result');
    out.innerHTML = '';
    withBusy(btn, api('test_s3', { run: '1' })).then(function (res) {
      if (!res.ok) { toast('bad', res.error || 'Test failed to run.'); return; }
      toast(res.passed ? 'ok' : 'bad', res.message);
      out.innerHTML =
        '<div class="note ' + (res.passed ? 'note-ok' : 'note-bad') + '" style="margin-top:14px">' +
          svg(res.passed ? 'checkc' : 'alert') +
          '<div><b>' + esc(res.message) + '</b>' +
            '<details class="raw" style="margin-top:8px"><summary>Show what was checked</summary>' +
            '<pre class="console">' + esc(res.output) + '</pre></details></div></div>';
    }).catch(function () {});
  }

  function onRunNow(btn) {
    withBusy(btn, api('run_now', { go: '1' })).then(function (res) {
      if (!res.ok) { toast('bad', res.error); return; }
      toast('ok', res.message);
      STATE.running = true;
      renderDynamic();
      showTab('logs');
    }).catch(function () {});
  }

  function onBackupUser(btn, user) {
    withBusy(btn, api('backup_user', { user: user })).then(function (res) {
      if (!res.ok) { toast('bad', res.error); return; }
      toast('ok', res.message);
      refreshState(true);
      refreshLog().catch(function () {});
    }).catch(function () {});
  }

  // --------------------------------------------------------- restore flow
  function openRestore(preselect) {
    var withBackups = STATE.accounts.filter(function (r) { return r.total_backups > 0; });
    if (!withBackups.length) {
      toast('bad', 'No account has a backup to restore yet.');
      return;
    }

    var body =
      '<p>Pick what to put back. This <b>overwrites live data</b> and cannot be undone.</p>' +
      '<div class="grid" style="margin-top:14px; grid-template-columns:1fr">' +
        '<div class="field"><label for="m-user">Account</label><select id="m-user">' +
          withBackups.map(function (r) {
            return '<option value="' + esc(r.user) + '"' + (r.user === preselect ? ' selected' : '') + '>' +
                   esc(r.user) + ' — ' + r.total_backups + ' backup' + (r.total_backups === 1 ? '' : 's') + '</option>';
          }).join('') +
        '</select></div>' +
        '<div class="field"><label for="m-date">Backup date</label><select id="m-date"></select></div>' +
        '<div class="field"><label for="m-db">What to restore</label><select id="m-db"></select></div>' +
      '</div>';

    modal({
      icon: 'rotate',
      title: 'Restore from backup',
      body: body,
      danger: true,
      confirmLabel: 'Restore now',
      ready: function (box) {
        var uSel = box.querySelector('#m-user'),
            dSel = box.querySelector('#m-date'),
            bSel = box.querySelector('#m-db');

        function backupsFor(user) {
          var row = STATE.accounts.filter(function (r) { return r.user === user; })[0];
          return (row && row.backups) || [];
        }
        function fillDates() {
          var list = backupsFor(uSel.value);
          dSel.innerHTML = list.map(function (b) {
            return '<option value="' + esc(b.date) + '">' + esc(b.date) +
                   ' (' + esc(b.full_size || '?') + ')</option>';
          }).join('');
          fillTargets();
        }
        function fillTargets() {
          var entry = backupsFor(uSel.value).filter(function (b) { return b.date === dSel.value; })[0];
          var dbs = (entry && entry.databases) || [];
          bSel.innerHTML = '<option value="">Entire account (files, mail, DNS, databases)</option>' +
            dbs.map(function (d) { return '<option value="' + esc(d) + '">Only database: ' + esc(d) + '</option>'; }).join('');
        }
        uSel.addEventListener('change', fillDates);
        dSel.addEventListener('change', fillTargets);
        fillDates();
      },
      collect: function (box) {
        return {
          user: box.querySelector('#m-user').value,
          date: box.querySelector('#m-date').value,
          db:   box.querySelector('#m-db').value
        };
      }
    }).then(function (pick) {
      if (!pick) return;
      var what = pick.db ? 'database ' + pick.db : 'the entire account';
      modal({
        icon: 'alert',
        title: 'Confirm restore',
        danger: true,
        confirmLabel: 'Yes, overwrite ' + (pick.db ? 'the database' : 'the account'),
        body: '<p>This replaces <b>' + esc(what) + '</b> for <b>' + esc(pick.user) + '</b> with the backup from ' +
              '<b>' + esc(pick.date) + '</b>.</p><ul><li>Live data is overwritten immediately.</li>' +
              '<li>There is no undo.</li><li>The job starts within a minute.</li></ul>'
      }).then(function (yes) {
        if (!yes) return;
        api('admin_restore', pick).then(function (res) {
          if (!res.ok) { toast('bad', res.error); return; }
          toast('ok', res.message);
          showTab('restores');
          refreshState(true);
        }).catch(function (err) { toast('bad', err.message); });
      });
    });
  }

  // ---------------------------------------------------------- update flow
  function onUpdateCheck(btn) {
    withBusy(btn, api('update_check')).then(function (res) {
      if (!res.ok) { toast('bad', res.error); return; }
      updateInfo = res;
      toast(res.available ? 'info' : 'ok', res.message);
      renderBanner();
      paintIcons($('sky-banner'));
      $('sky-version').className = 'vpill' + (res.available ? ' has-update' : '');
    }).catch(function () {});
  }

  function onUpdateApply(btn) {
    modal({
      icon: 'download',
      title: 'Install update',
      confirmLabel: 'Install now',
      body: '<p>Pulls the latest module code from GitHub and redeploys it.</p>' +
            '<ul><li>Your configuration is left untouched.</li>' +
            '<li>Existing backups in S3 are left untouched.</li>' +
            '<li>Takes a few seconds; backups keep running on schedule.</li></ul>'
    }).then(function (yes) {
      if (!yes) return;
      withBusy(btn, api('update_apply', { go: '1' })).then(function (res) {
        showUpdateResult(res);
        if (res.ok) {
          updateInfo = null;
          if (res.state) STATE = res.state;
          $('sky-version').textContent = 'v' + STATE.version;
          $('sky-version').className = 'vpill';
          renderAll();
        }
      }).catch(function () {});
    });
  }

  /**
   * The raw output of an update is a git fetch, deploy.sh's commentary and
   * one version line. Dumping all of it in a black box said nothing and
   * read like a failure even when it worked — so the deploy steps become a
   * checklist, the version is the headline, and the raw text stays one
   * click away for when something actually breaks.
   */
  function showUpdateResult(res) {
    var r = res.result || { steps: [], raw: '' };
    var ok = res.ok;

    var steps = r.steps.length
      ? '<ul class="steps" style="margin-top:6px">' + r.steps.map(function (s) {
          return '<li class="' + (s.sub ? 'sub ' : '') + s.level + '">' +
                 svg(s.level === 'ok' ? 'check' : 'alert') + '<span>' + esc(s.text) + '</span></li>';
        }).join('') + '</ul>'
      : '';

    modal({
      icon: ok ? 'checkc' : 'alert',
      tone: ok ? 'good' : 'danger',
      title: ok ? 'Updated to v' + r.version : 'Update did not complete',
      single: true,
      confirmLabel: 'Done',
      body: '<p>' + (ok
          ? 'The module was pulled from GitHub and redeployed. Backups keep running on their existing schedule.'
          : 'The update stopped before finishing. Nothing was removed — the previous version is still installed.') +
        '</p>' + steps +
        '<details class="raw"><summary>Show raw output</summary>' +
          '<pre class="console">' + esc(r.raw || '(no output)') + '</pre></details>'
    });

    toast(ok ? 'ok' : 'bad', res.message);
  }

  // Wired in init(); assigned here so the render and action code above can
  // call it without caring how the tab strip is built.
  var showTab = function () {};

  // ------------------------------------------------------ event wiring
  // One delegated listener for the whole panel: every table row, card and
  // modal is re-rendered from state, so per-element handlers would have to
  // be re-attached on every repaint.
  document.addEventListener('click', function (e) {
    var goto = e.target.closest ? e.target.closest('[data-goto]') : null;
    if (goto) {
      e.preventDefault();
      showTab(goto.dataset.goto);
      return;
    }

    var btn = e.target.closest ? e.target.closest('[data-act]') : null;
    if (!btn) return;
    var act = btn.dataset.act;

    if (act === 'run-now')          onRunNow(btn);
    else if (act === 'backup-user') onBackupUser(btn, btn.dataset.user);
    else if (act === 'restore')     openRestore(btn.dataset.user || null);
    else if (act === 'test-s3')     onTestS3(btn);
    else if (act === 'refresh')     withBusy(btn, refreshState()).catch(function () {});
    else if (act === 'refresh-log') withBusy(btn, refreshLog()).catch(function () {});
  });

  $('sky-refresh').addEventListener('click', function () {
    var btn = this;
    withBusy(btn, Promise.all([refreshState(), refreshLog()])).then(function () {
      toast('ok', 'Refreshed.');
    }).catch(function () {});
  });

  $('sky-update-check').addEventListener('click', function () { onUpdateCheck(this); });

  // The "Install update" button lives inside the banner, which is redrawn
  // whenever the state changes, so it is reached through the banner rather
  // than bound directly.
  $('sky-banner').addEventListener('click', function (e) {
    if (e.target.id === 'sky-update-apply') onUpdateApply(e.target);
  });

  // ---------------------------------------------------------------- init
  UI.initTheme();

  // WHM prints its own logo and a row of cpanel.net links above plugin
  // content, and caps the width of the container it puts us in. Neither
  // helps a panel that has its own heading and its own tables.
  UI.hideChromeBranding();
  UI.fillWidth();

  renderAll();

  showTab = UI.tabs(['overview', 'accounts', 'restores', 'settings', 'logs'], function (name) {
    if (name === 'logs') {
      var pre = $('sky-log');
      if (pre) pre.scrollTop = pre.scrollHeight;
    }
  });

})();
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
    echo '<div class="sky" id="sky-root" data-theme="light">' . $body . '</div>';
    echo whm_chrome('deffooter');
} else {
    echo "<!DOCTYPE html>\n<html>\n<head>\n";
    echo '<meta charset="utf-8">' . "\n";
    echo '<meta name="viewport" content="width=device-width, initial-scale=1">' . "\n";
    echo "<title>SkyServer Backup Manager</title>\n";
    echo $SKY_STYLES;
    echo "<style>html,body { margin:0; padding:0; background:#f6f7f9; }</style>\n";
    echo "</head>\n<body>\n";
    echo '<div class="sky" id="sky-root" data-theme="light">' . $body . '</div>';
    echo "\n</body>\n</html>\n";
}
