// board --serve: a zero-dependency local web kanban over crm.db.
// One page, auto-refreshing via fetch polling; strictly one column per
// status, same as the CLI board. Clicking a card opens the task's full
// journey: status timeline (mechanically logged by the
// log_status_transition trigger), agent events, files, deps, description.
import { createServer } from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { existsSync } from 'node:fs';
import { dirname } from 'node:path';
import { fetchBoardTasks } from './board.mjs';
import { loadConfig } from './config.mjs';

const BOARD_STATUSES = [
  'BACKLOG',
  'PLANNING',
  'READY_FOR_DEV',
  'CODING',
  'READY_FOR_REVIEW',
  'REVIEWING',
  'READY_FOR_TEST',
  'TESTING',
  'READY_FOR_DOCS',
  'DOCUMENTING',
  'DONE',
];
const EXIT_STATUSES = ['BLOCKED', 'CANCELLED'];

// Only enabled stages appear as columns (reviewEnabled/testsEnabled/
// docsEnabled from config.json); a disabled stage's column still shows up
// while a task actually sits in it, so nothing ever disappears from view.
export function enabledBoardStatuses(config) {
  // BACKLOG and PLANNING are deliberately absent: SOLO — the common
  // route — opens work straight in READY_FOR_DEV, so those columns would
  // sit empty forever. The client still renders any status that actually
  // holds a task, so a PLAN run shows them the moment they fill.
  const enabled = ['READY_FOR_DEV', 'CODING'];
  if (config.reviewEnabled) enabled.push('READY_FOR_REVIEW', 'REVIEWING');
  if (config.testsEnabled) enabled.push('READY_FOR_TEST', 'TESTING');
  if (config.docsEnabled) enabled.push('READY_FOR_DOCS', 'DOCUMENTING');
  enabled.push('DONE');
  return enabled;
}
const DEFAULT_PORT = 4553;
const POLL_MS = 2000;

function fetchTaskDetail(database, taskId) {
  const task = database
    .prepare('SELECT id, title, description, status, assigned_agent, locked_at, loop_count, error_log_path, resolution_hint, summary FROM tasks WHERE id = ?')
    .get(taskId);
  if (!task) {
    return null;
  }
  const files = database.prepare('SELECT path FROM task_files WHERE task_id = ? ORDER BY path').all(taskId);
  const deps = database
    .prepare(
      `SELECT task_deps.depends_on_id AS id, tasks.title AS title, tasks.status AS status
       FROM task_deps JOIN tasks ON tasks.id = task_deps.depends_on_id
       WHERE task_deps.task_id = ? ORDER BY task_deps.depends_on_id`,
    )
    .all(taskId);
  const trace = database
    .prepare('SELECT created_at, kind, agent, detail FROM events WHERE task_id = ? ORDER BY id')
    .all(taskId);
  return { task, files, deps, trace };
}

const PAGE = `<!doctype html>
<meta charset="utf-8">
<title>Agent Scrum board</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font: 13px/1.4 system-ui, sans-serif; background: #f4f4f2; color: #222; }
  @media (prefers-color-scheme: dark) {
    body { background: #1d1e20; color: #ddd; }
    .col { background: #26272a !important; }
    .card { background: #313236 !important; border-color: #3d3e42 !important; }
    #detail { background: #26272a !important; border-color: #3d3e42 !important; }
    .ev { border-color: #3d3e42 !important; }
  }
  header { padding: 10px 16px; display: flex; gap: 16px; align-items: baseline; }
  header h1 { font-size: 15px; margin: 0; }
  #summary { opacity: .7; }
  #board { display: flex; gap: 8px; padding: 0 12px 12px; overflow-x: auto; align-items: flex-start; }
  .col { background: #e9e9e6; border-radius: 8px; padding: 8px; min-width: 150px; flex: 1; }
  .col h2 { font-size: 11px; letter-spacing: .04em; margin: 0 0 6px 2px; opacity: .65; }
  .card { background: #fff; border: 1px solid #ddd; border-radius: 6px; padding: 6px 8px; margin-bottom: 6px; cursor: pointer; }
  .card:hover { border-color: #7a9; }
  .card .id { font-weight: 600; margin-right: 4px; }
  .card .agent { display: block; font-size: 11px; opacity: .6; margin-top: 2px; }
  .card .summary { display: block; font-size: 11px; opacity: .8; margin-top: 3px; border-left: 2px solid #4a8; padding-left: 5px; }
  .card .loops { color: #b5651d; font-size: 11px; }
  .blocked { padding: 6px 16px 12px; color: #b03030; }
  .count { opacity: .5; font-weight: 400; }
  #overlay { position: fixed; inset: 0; background: rgba(0,0,0,.35); display: none; }
  #detail { position: fixed; top: 0; right: 0; bottom: 0; width: min(560px, 90vw); background: #fff;
            border-left: 1px solid #ddd; overflow-y: auto; padding: 14px 18px; display: none; }
  #detail h2 { margin: 0 0 2px; font-size: 15px; }
  #detail .meta { font-size: 12px; opacity: .75; margin-bottom: 10px; }
  #detail h3 { font-size: 12px; letter-spacing: .04em; opacity: .65; margin: 14px 0 6px; }
  .ev { border-left: 2px solid #ccc; padding: 3px 0 3px 10px; margin-left: 4px; }
  .ev time { font-size: 11px; opacity: .55; margin-right: 6px; }
  .ev .kind { display: inline-block; font-size: 10px; padding: 0 5px; border-radius: 8px; background: #8882; margin-right: 6px; }
  .ev.status { border-left-color: #4a8; }
  .ev.status .kind { background: #4a83; }
  .ev.blocker { border-left-color: #b03030; }
  .ev .agent { font-size: 11px; opacity: .6; }
  #detail pre { white-space: pre-wrap; font: 12px/1.4 ui-monospace, monospace; background: #8881; padding: 8px; border-radius: 6px; }
  #close { float: right; cursor: pointer; border: 0; background: none; font-size: 16px; color: inherit; }
</style>
<header><h1>Agent Scrum board</h1><div id="summary"></div></header>
<div id="board"></div>
<div id="blocked" class="blocked"></div>
<div id="overlay"></div>
<div id="detail"></div>
<script>
const STATUSES = ${JSON.stringify(BOARD_STATUSES)};
let openTaskId = null;
function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }
async function refresh() {
  try {
    const data = await (await fetch('/data')).json();
    const byStatus = {};
    for (const s of STATUSES) byStatus[s] = [];
    const exits = [];
    for (const t of data.tasks) (byStatus[t.status] || exits).push(t);
    const enabled = new Set(data.enabledStatuses || STATUSES);
    const visible = STATUSES.filter((s) => enabled.has(s) || byStatus[s].length > 0);
    document.getElementById('board').innerHTML = visible.map((s) => {
      const cards = byStatus[s].map((t) =>
        '<div class="card" onclick="openTask(' + t.id + ')" title="' + esc(t.title) + '"><span class="id">#' + t.id + '</span>' + esc(t.title) +
        (t.loop_count > 0 ? ' <span class="loops">↻' + t.loop_count + '</span>' : '') +
        (t.summary ? '<span class="summary">' + esc(t.summary) + '</span>' : '') +
        (t.assigned_agent ? '<span class="agent">' + esc(t.assigned_agent) + (t.stale ? ' — stale' : '') + '</span>' : '') + '</div>'
      ).join('');
      return '<div class="col"><h2>' + s + ' <span class="count">' + byStatus[s].length + '</span></h2>' + cards + '</div>';
    }).join('');
    document.getElementById('blocked').textContent = exits.length
      ? 'BLOCKED/CANCELLED: ' + exits.map((t) => '#' + t.id + ' ' + t.title + ' [' + t.status + ']').join(', ')
      : '';
    document.getElementById('summary').textContent =
      'total ' + data.tasks.length + ' | done ' + byStatus.DONE.length + ' | blocked ' + exits.length +
      ' | updated ' + new Date().toLocaleTimeString();
    if (openTaskId !== null) renderDetail(openTaskId);
  } catch { /* next poll retries */ }
}
async function renderDetail(id) {
  try {
    const d = await (await fetch('/task?id=' + id)).json();
    if (!d.task) return;
    const t = d.task;
    document.getElementById('detail').innerHTML =
      '<button id="close" onclick="closeTask()">✕</button>' +
      '<h2>#' + t.id + ' ' + esc(t.title) + '</h2>' +
      '<div class="meta">' + esc(t.status) +
        (t.assigned_agent ? ' · ' + esc(t.assigned_agent) : '') +
        (t.locked_at ? ' · claimed ' + esc(t.locked_at) : '') +
        (t.loop_count > 0 ? ' · ↻' + t.loop_count + ' returns' : '') +
        (t.resolution_hint ? '<br>hint: ' + esc(t.resolution_hint) : '') +
        (t.error_log_path ? '<br>log: ' + esc(t.error_log_path) : '') + '</div>' +
      (t.summary ? '<h3>What was done</h3><div class="ev status">' + esc(t.summary) + '</div>' : '') +
      '<h3>Journey (' + d.trace.length + ' events)</h3>' +
      (d.trace.length === 0 ? '<div class="ev">no events yet</div>' :
        d.trace.map((e) =>
          '<div class="ev ' + esc(e.kind) + '"><time>' + esc(e.created_at) + '</time>' +
          '<span class="kind">' + esc(e.kind) + '</span>' + esc(e.detail) +
          ' <span class="agent">— ' + esc(e.agent) + '</span></div>').join('')) +
      '<h3>Files</h3><div>' + (d.files.length ? d.files.map((f) => esc(f.path)).join('<br>') : 'none') + '</div>' +
      '<h3>Depends on</h3><div>' + (d.deps.length ? d.deps.map((x) => '#' + x.id + ' [' + esc(x.status) + '] ' + esc(x.title)).join('<br>') : 'none') + '</div>' +
      '<h3>Description</h3><pre>' + esc(t.description) + '</pre>';
    document.getElementById('detail').style.display = 'block';
    document.getElementById('overlay').style.display = 'block';
  } catch { /* keep previous panel */ }
}
function openTask(id) { openTaskId = id; renderDetail(id); }
function closeTask() {
  openTaskId = null;
  document.getElementById('detail').style.display = 'none';
  document.getElementById('overlay').style.display = 'none';
}
document.getElementById('overlay').addEventListener('click', closeTask);
refresh();
setInterval(refresh, ${POLL_MS});
</script>
`;

export function serveBoard(dbPath, port = DEFAULT_PORT) {
  if (!existsSync(dbPath)) {
    process.stderr.write('no scrum_crm/crm.db — run node scrum_crm/crm.mjs init or install first\n');
    process.exit(1);
  }

  const server = createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    if (url.pathname === '/data') {
      // A fresh read-only connection per poll: sees other processes' writes.
      const database = new DatabaseSync(dbPath);
      const tasks = fetchBoardTasks(database);
      database.close();
      const enabled = enabledBoardStatuses(loadConfig(dirname(dbPath)));
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ tasks, enabledStatuses: enabled }));
      return;
    }
    if (url.pathname === '/task') {
      const database = new DatabaseSync(dbPath);
      const detail = fetchTaskDetail(database, Number(url.searchParams.get('id')));
      database.close();
      res.writeHead(detail ? 200 : 404, { 'content-type': 'application/json' });
      res.end(JSON.stringify(detail ?? { error: 'no such task' }));
      return;
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(PAGE);
  });

  server.listen(port, '127.0.0.1', () => {
    process.stdout.write(`board: http://127.0.0.1:${port} (Ctrl-C to stop)\n`);
  });
}
