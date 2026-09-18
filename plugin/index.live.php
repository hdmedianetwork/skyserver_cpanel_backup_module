<?php
/**
 * SkyServer Backup Manager — cPanel end-user page.
 *
 * Built from the same design system as the WHM admin dashboard
 * (ui/sky-ui.php, copied next to both by bin/deploy.sh), so a customer and
 * their host are looking at the same thing.
 *
 * The page is a shell: PHP renders it once with a snapshot of this
 * account's backups embedded in it, and every button after that goes
 * through status.live.php (reads) and action.live.php (queueing). Nothing
 * reloads, and a restore is never performed here — the plugin only drops a
 * request file into a queue that bin/restore-worker.sh, running as root,
 * picks up. That is the privilege boundary.
 */

require_once __DIR__ . '/liveapi.php';
require_once __DIR__ . '/manifest.php';
require_once __DIR__ . '/sky-ui.php';

$user = getenv('REMOTE_USER');
if (!$user || !preg_match('/^[a-zA-Z0-9_]+$/', $user)) {
    http_response_code(403);
    die('Unable to determine cPanel user.');
}

// Opened before anything is printed: cPanel serves .live.php pages through
// LiveAPI and expects the script to make that connection, and prints
// "Child failed to make LIVEAPI connection to cPanel." under the page when
// it doesn't. It is also what gives us cPanel's own sidebar and footer.
$cpanel = liveapi_connect();

$initialState = sky_user_state($user);
$SKY_STYLES = sky_styles();

ob_start();
?>
<div class="wrap">

  <div class="mast">
    <img src="https://ik.imagekit.io/hdmn/skybackupmanager.png" alt="SkyServer Backup Manager">
    <div class="titles">
      <h1>Backup Manager</h1>
      <div class="sub">
        Automatic daily backups for <strong><?= htmlspecialchars($user) ?></strong>, stored securely off-server
      </div>
    </div>
    <div class="spacer"></div>
    <div class="tools">
      <button class="btn btn-icon" id="sky-theme" title="Switch between light and dark" aria-label="Switch theme"></button>
      <button class="btn" id="sky-refresh" data-icon="refresh">Refresh</button>
    </div>
  </div>

  <div id="sky-banner"></div>
  <div class="tiles" id="sky-tiles"></div>

  <div class="tabs" role="tablist" id="sky-tabs">
    <button class="tab" role="tab" data-tab="backups" data-icon="drive" aria-selected="true">Account backups <span class="count" id="c-backups">0</span></button>
    <button class="tab" role="tab" data-tab="databases" data-icon="db" aria-selected="false">Databases <span class="count" id="c-dbs">0</span></button>
  </div>

  <div class="panel" id="p-backups"></div>
  <div class="panel" id="p-databases" hidden></div>

  <noscript>
    <div class="note note-warn" style="margin-top:16px">
      This page needs JavaScript. cPanel itself requires it too, so enabling it for this
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

  var UI = window.SkyUI;
  var svg = UI.svg, esc = UI.esc, bytes = UI.bytes, ago = UI.ago,
      toast = UI.toast, modal = UI.modal, withBusy = UI.withBusy,
      paintIcons = UI.paintIcons, emptyState = UI.emptyState;
  var $ = function (id) { return document.getElementById(id); };

  // One entry per row the customer has acted on, keyed the same way the row
  // is, so a re-render puts the pill back where it belongs instead of
  // losing it. Nothing here is persisted: a reload starts clean, and the
  // request itself lives in the queue on the server either way.
  var JOBS = {};
  var pollTimer = null;
  var showTab = function () {};

  function key(type, date, db) { return type + '|' + date + '|' + (db || ''); }

  // ------------------------------------------------------------- renders
  function tile(cls, iconName, label, value, meta) {
    return '<div class="tile ' + cls + '"><div class="ico">' + svg(iconName) + '</div>' +
           '<div><div class="k">' + esc(label) + '</div><div class="v">' + value + '</div>' +
           (meta ? '<div class="meta">' + meta + '</div>' : '') + '</div></div>';
  }

  function renderTiles() {
    var t = STATE.totals;
    var days = UI.daysSince(t.lastDate);
    var fresh = days !== null && days <= 1;

    $('sky-tiles').innerHTML =
      tile(t.count ? 'ok' : '', 'shield', 'Backups kept',
           t.count, t.count ? 'one per day, oldest removed automatically' : 'nothing stored yet') +
      tile(t.count ? (fresh ? 'ok' : 'warn') : '', 'clock', 'Last backup',
           esc(t.lastDate || '—'),
           days === null ? 'no backup has run yet'
             : days === 0 ? 'taken today' : days === 1 ? 'taken yesterday' : days + ' days ago') +
      tile('', 'cloud', 'Last backup size', esc(t.lastSize || '—'),
           t.bytes ? bytes(t.bytes) + ' stored in total' : '') +
      tile('', 'db', 'Databases', t.databases,
           t.databases ? 'each one also backed up on its own' : 'none on this account');

    $('c-backups').textContent = STATE.backups.length;
    $('c-dbs').textContent = STATE.totals.databases;
  }

  function renderBanner() {
    var out = '';
    var b = STATE.backupRunning;
    if (b) {
      out += '<div class="note note-ok" style="margin-bottom:14px">' + svg('zap') +
             '<div style="flex:1 1 auto"><b>A backup of your account is running right now.</b> ' +
             'You can keep using your site — nothing is taken offline.' +
             progressBlock(b) + '</div></div>';
    }
    if (!STATE.visible) {
      out += '<div class="note note-warn" style="margin-bottom:14px">' + svg('alert') +
             '<div><b>Your backup history can\'t be read right now.</b> Your backups are most ' +
             'likely still running normally — this page just can\'t see them. Please contact ' +
             'support and mention "backup manifest unreadable".</div></div>';
    } else if (!STATE.restoreEnabled) {
      out += '<div class="note" style="margin-bottom:14px">' + svg('lock') +
             '<div><b>Your backups are running normally.</b> Restoring a backup yourself is ' +
             'turned off on this server — you can still download any backup, and support can ' +
             'restore one for you.</div></div>';
    }
    $('sky-banner').innerHTML = out;
  }

  /**
   * What is happening, right now, in words the customer can act on — with a
   * bar that keeps moving even before a percentage is known, so "working"
   * never reads as "stuck".
   */
  function progressBlock(p) {
    var known = typeof p.percent === 'number' && p.percent >= 0;
    return '<div class="prog">' +
      '<div class="top"><span class="what">' + esc(p.message || 'Working') + '</span>' +
        (p.step && p.steps
          ? '<span class="steps-of">' + p.step + '/' + p.steps + '</span>' : '') +
        (known ? '<span class="pc">' + Math.round(p.percent) + '%</span>' : '') +
      '</div>' +
      (p.detail ? '<div class="sub">' + esc(p.detail) + '</div>' : '') +
      '<div class="bar' + (known ? '' : ' indet') + '">' +
        '<i style="width:' + (known ? Math.max(2, Math.min(100, p.percent)) : 100) + '%"></i>' +
      '</div>' +
    '</div>';
  }

  /** What replaces a row's buttons while its request is in flight. */
  function jobCell(k) {
    var j = JOBS[k];
    if (!j) return '';
    if (j.status === 'ready' && j.url) {
      return ' <a class="dl-link" href="' + esc(j.url) + '">Download ready — click if it didn\'t start</a>';
    }
    if (j.status === 'failed') {
      return ' <span class="pill pill-bad">failed</span>' +
             (j.error ? ' <span class="dim" style="font-size:12px">' + esc(j.error) + '</span>' : '');
    }
    if (j.status === 'success') {
      return ' <span class="pill pill-ok">done</span>';
    }
    // Queued means the worker has not picked it up yet — it runs once a
    // minute — so say that rather than showing a bar at zero forever.
    if (j.status === 'queued' && !j.message) {
      return progressBlock({ message: j.label === 'restoring' ? 'Waiting to start the restore'
                                                              : 'Waiting to start',
                             detail: 'picked up within a minute' });
    }
    return progressBlock(j);
  }

  function actions(type, date, db) {
    var k = key(type, date, db);
    if (JOBS[k]) return jobCell(k);

    var attrs = 'data-date="' + esc(date) + '"' + (db ? ' data-db="' + esc(db) + '"' : '');
    var out = '';
    if (type === 'account') {
      out += '<button class="btn btn-sm" data-act="download" ' + attrs + '>Download</button> ';
    }
    if (STATE.restoreEnabled) {
      out += '<button class="btn btn-sm" data-act="restore" data-type="' +
             (db ? 'database' : 'full') + '" ' + attrs + '>Restore</button>';
    }
    return out;
  }

  function renderBackups() {
    var body = STATE.backups.length
      ? '<div class="tbl-scroll"><table><thead><tr>' +
          '<th>Date</th><th>Size</th><th>Includes</th><th class="right">Actions</th>' +
        '</tr></thead><tbody>' +
        STATE.backups.map(function (b) {
          var dbs = b.databases || [];
          return '<tr>' +
            '<td class="nowrap mono"><b>' + esc(b.date) + '</b></td>' +
            '<td class="nowrap mono">' + esc(b.full_size || '—') + '</td>' +
            '<td class="dim">Files, email, DNS' +
              (dbs.length ? ' and <span class="chip">' + dbs.length + ' database' + (dbs.length === 1 ? '' : 's') + '</span>' : '') +
            '</td>' +
            '<td class="right nowrap">' + actions('account', b.date) + '</td>' +
          '</tr>';
        }).join('') + '</tbody></table></div>'
      : emptyState('inbox',
          STATE.visible ? 'No backups yet' : 'Backup history unavailable',
          STATE.visible ? 'The first daily backup will appear here once it has run.'
                        : 'See the notice above.');

    $('p-backups').innerHTML =
      '<div class="card">' +
        '<header><div class="grow"><h2>Account backups</h2>' +
          '<div class="hint">A complete copy of your account — files, email, DNS and databases.</div></div>' +
        '</header>' + body +
      '</div>' +
      '<div class="card"><div class="body"><div class="note">' + svg('info') +
        '<div><b>Downloads are a private, time-limited link.</b> Preparing one takes up to a ' +
        'minute; the download then starts on its own and the link expires after an hour.' +
        (STATE.restoreEnabled
          ? ' <b>Restoring overwrites your live data and cannot be undone.</b>' : '') +
        '</div></div></div></div>';
  }

  function renderDatabases() {
    var rows = [];
    STATE.backups.forEach(function (b) {
      (b.databases || []).forEach(function (db) { rows.push({ date: b.date, db: db }); });
    });

    var body = rows.length
      ? '<div class="tbl-scroll"><table><thead><tr>' +
          '<th>Date</th><th>Database</th>' +
          (STATE.restoreEnabled ? '<th class="right">Actions</th>' : '') +
        '</tr></thead><tbody>' +
        rows.map(function (r) {
          return '<tr>' +
            '<td class="nowrap mono">' + esc(r.date) + '</td>' +
            '<td><span class="chip">' + esc(r.db) + '</span></td>' +
            (STATE.restoreEnabled
              ? '<td class="right nowrap">' + actions('database', r.date, r.db) + '</td>' : '') +
          '</tr>';
        }).join('') + '</tbody></table></div>'
      : emptyState('db',
          STATE.visible ? 'No databases in your backups' : 'Backup history unavailable',
          STATE.visible ? 'This account has no databases, so there is nothing to list here.'
                        : 'See the notice above.');

    $('p-databases').innerHTML =
      '<div class="card">' +
        '<header><div class="grow"><h2>Databases</h2>' +
          '<div class="hint">Each database is also stored on its own, so one can be put back ' +
            'without rolling back the whole account.</div></div>' +
        '</header>' + body +
      '</div>';
  }

  function renderAll() {
    renderTiles();
    renderBanner();
    renderBackups();
    renderDatabases();
    paintIcons(document);
    syncPolling();
  }

  // ------------------------------------------------------------- polling
  function jobsBusy() {
    return Object.keys(JOBS).some(function (k) {
      return JOBS[k].status === 'queued' || JOBS[k].status === 'running';
    });
  }

  function syncPolling() {
    var busy = jobsBusy() || !!STATE.backupRunning;
    if (busy && !pollTimer) {
      pollTimer = setInterval(function () {
        // Re-checked on every tick rather than captured when the timer was
        // created: what is in flight changes while it runs.
        if (jobsBusy()) pollAll();
        // A backup is the server's own work, so its progress only arrives
        // with a fresh read of the state.
        refreshState(true);
      }, 3000);
    } else if (!busy && pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  }

  function pollAll() {
    Object.keys(JOBS).forEach(function (k) {
      var j = JOBS[k];
      if (j.status !== 'queued' && j.status !== 'running') return;

      UI.api('status.live.php?id=' + encodeURIComponent(j.id)).then(function (res) {
        if (!res.ok) { j.status = 'failed'; j.error = res.error; renderAll(); return; }

        if (res.status === 'success' && res.download_url) {
          // The link is a short-lived S3 URL, so start the download straight
          // away and leave it clickable in case the browser blocks that.
          j.status = 'ready';
          j.url = res.download_url;
          renderAll();
          toast('ok', 'Your download is ready.');
          window.location.href = res.download_url;
          return;
        }

        j.status  = res.status;
        j.label   = res.status === 'running' ? (j.type === 'download' ? 'preparing' : 'restoring') : res.status;
        j.error   = res.error || null;
        j.message = res.message || null;
        j.detail  = res.detail || null;
        j.step    = res.step || null;
        j.steps   = res.steps || null;
        j.percent = (typeof res.percent === 'number') ? res.percent : null;
        if (res.status === 'success') toast('ok', 'Restore finished.');
        if (res.status === 'failed')  toast('bad', res.error || 'The request failed.');
        renderAll();
      }).catch(function () {
        // A poll that fails is not worth a toast every three seconds; the
        // next one usually succeeds.
      });
    });
  }

  // ------------------------------------------------------------- actions
  function queue(btn, type, date, db, label) {
    var k = key(type === 'download' ? 'account' : (db ? 'database' : 'account'), date, db);
    return withBusy(btn, UI.api('action.live.php', { type: type, date: date, db: db || '' }))
      .then(function (res) {
        if (!res.ok) { toast('bad', res.error || 'The request was refused.'); return; }
        JOBS[k] = { id: res.id, type: type, status: 'queued', label: label };
        toast('info', type === 'download'
          ? 'Preparing your download — this can take up to a minute.'
          : 'Restore queued — it starts within a minute.');
        renderAll();
      }).catch(function () {});
  }

  function onDownload(btn) {
    queue(btn, 'download', btn.dataset.date, '', 'preparing');
  }

  function onRestore(btn) {
    var date = btn.dataset.date, db = btn.dataset.db || '';
    var what = db ? 'the database <b>' + esc(db) + '</b>' : '<b>your entire account</b>';

    modal({
      icon: 'alert',
      danger: true,
      title: 'Restore from ' + date + '?',
      confirmLabel: db ? 'Yes, overwrite this database' : 'Yes, overwrite my account',
      body: '<p>This replaces ' + what + ' with the backup taken on <b>' + esc(date) + '</b>.</p>' +
            '<ul><li>Everything changed since then is lost.</li>' +
            '<li>There is no undo.</li>' +
            '<li>The restore starts within a minute and runs in the background.</li></ul>'
    }).then(function (yes) {
      if (yes) queue(btn, db ? 'database' : 'full', date, db, 'restoring');
    });
  }

  function refreshState(quiet) {
    return UI.api('status.live.php?api=state').then(function (res) {
      if (!res.ok) throw new Error(res.error || 'Could not read your backups.');
      STATE = res.state;
      renderAll();
    }).catch(function (err) {
      if (!quiet) throw err;
    });
  }

  // -------------------------------------------------------- event wiring
  // One delegated listener: the tables are re-rendered from state, so
  // per-button handlers would have to be re-attached on every repaint.
  document.addEventListener('click', function (e) {
    var btn = e.target.closest ? e.target.closest('[data-act]') : null;
    if (!btn) return;
    if (btn.dataset.act === 'download')     onDownload(btn);
    else if (btn.dataset.act === 'restore') onRestore(btn);
  });

  $('sky-refresh').addEventListener('click', function () {
    var btn = this;
    withBusy(btn, refreshState()).then(function () { toast('ok', 'Refreshed.'); })
      .catch(function () {});
  });

  // ---------------------------------------------------------------- init
  UI.initTheme();

  // cPanel prints its own logo and a row of cpanel.net links above plugin
  // content, and caps the width of the container it puts us in. Neither
  // helps a page that has its own heading and its own tables.
  UI.hideChromeBranding();
  UI.fillWidth();

  renderAll();
  showTab = UI.tabs(['backups', 'databases']);
})();
</script>

<?php
$body = ob_get_clean();

// cPanel's chrome if LiveAPI gave us a document, our own page if it didn't —
// the plugin stays usable on a server where the connection isn't available.
$header = $cpanel ? (string) $cpanel->header('Backup Manager') : '';

if (stripos($header, '<html') !== false) {
    echo $header;
    echo $SKY_STYLES;
    echo '<div class="sky" id="sky-root" data-theme="light">' . $body . '</div>';
    echo (string) $cpanel->footer();
} else {
    echo "<!DOCTYPE html>\n<html>\n<head>\n";
    echo '<meta charset="utf-8">' . "\n";
    echo '<meta name="viewport" content="width=device-width, initial-scale=1">' . "\n";
    echo "<title>Backup Manager</title>\n";
    echo $SKY_STYLES;
    echo "<style>html,body { margin:0; padding:0; background:#f6f7f9; }</style>\n";
    echo "</head>\n<body>\n";
    echo '<div class="sky" id="sky-root" data-theme="light">' . $body . '</div>';
    echo "\n</body>\n</html>\n";
}

liveapi_end($cpanel);
