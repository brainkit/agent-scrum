// Board entry point. The human-facing board is web-only: `board [port]`
// serves the auto-refreshing kanban (boardWeb.mjs). For scripts/tests
// `board --json` dumps the same payload the web page polls; `--task N`
// prints a plain-text task card for debugging.
import { DatabaseSync } from 'node:sqlite';
import { existsSync } from 'node:fs';
import { claimIsDead } from './claimEventSweep.mjs';

const TRACE_EVENT_LIMIT = 20;
const DESCRIPTION_LINE_LIMIT = 15;
const STALE_LEASE_MINUTES = 30;

function exitWithNoDatabaseError() {
  console.error('no scrum_crm/crm.db — run node scrum_crm/crm.mjs init or install first');
  process.exit(1);
}

function openReadOnlyDatabase(dbPath) {
  if (!existsSync(dbPath)) {
    exitWithNoDatabaseError();
  }
  return new DatabaseSync(dbPath);
}

// The same rows /data serves: id, title, status, assigned_agent,
// loop_count, stale (claim older than the lease window).
export function fetchBoardTasks(database) {
  const rows = database
    .prepare(
      `SELECT id, title, status, assigned_agent, loop_count, priority,
              holder_pid, holder_start,
              CASE WHEN locked_at IS NULL THEN NULL
                   ELSE CAST((julianday('now') - julianday(locked_at)) * 1440 AS INTEGER) END AS age_minutes
       FROM tasks ORDER BY priority DESC, id`,
    )
    .all();
  // stale = the holder session is verifiably dead, or (no holder info)
  // the claim is older than the lease window — same rule the sweep uses.
  return rows.map(({ holder_pid, holder_start, age_minutes, ...task }) => ({
    ...task,
    stale: task.assigned_agent && claimIsDead({ holder_pid, holder_start, age_minutes }, STALE_LEASE_MINUTES) ? 1 : 0,
  }));
}

function fetchTaskById(database, taskId) {
  return database.prepare('SELECT * FROM tasks WHERE id = ?').get(taskId);
}

function fetchTaskFiles(database, taskId) {
  return database.prepare('SELECT path FROM task_files WHERE task_id = ? ORDER BY path').all(taskId);
}

function fetchTaskDeps(database, taskId) {
  return database
    .prepare(
      `SELECT task_deps.depends_on_id AS id, tasks.title AS title, tasks.status AS status
       FROM task_deps JOIN tasks ON tasks.id = task_deps.depends_on_id
       WHERE task_deps.task_id = ? ORDER BY task_deps.depends_on_id`,
    )
    .all(taskId);
}

function fetchTaskTrace(database, taskId) {
  const recentEventsDesc = database
    .prepare('SELECT created_at, kind, agent, detail FROM events WHERE task_id = ? ORDER BY id DESC LIMIT ?')
    .all(taskId, TRACE_EVENT_LIMIT);
  return recentEventsDesc.reverse();
}

function renderTaskCard(database, taskId) {
  const task = fetchTaskById(database, taskId);
  if (!task) {
    console.error(`no task with id ${taskId}`);
    process.exit(1);
  }

  console.log(`id: ${task.id}`);
  console.log(`title: ${task.title}`);
  console.log(`status: ${task.status}`);
  console.log(`agent: ${task.assigned_agent ?? ''}`);
  console.log(`locked_at: ${task.locked_at ?? ''}`);
  console.log(`loop_count: ${task.loop_count}`);
  console.log(`error_log_path: ${task.error_log_path ?? ''}`);
  console.log(`resolution_hint: ${task.resolution_hint ?? ''}`);

  const files = fetchTaskFiles(database, taskId);
  console.log('\nFiles:');
  console.log(files.length === 0 ? '(none)' : files.map((file) => `  ${file.path}`).join('\n'));

  const deps = fetchTaskDeps(database, taskId);
  console.log('\nDepends on:');
  console.log(deps.length === 0 ? '(none)' : deps.map((dep) => `  #${dep.id} [${dep.status}] ${dep.title}`).join('\n'));

  const trace = fetchTaskTrace(database, taskId);
  console.log('\nTrace:');
  console.log(
    trace.length === 0
      ? '(none)'
      : trace.map((event) => `  ${event.created_at} ${event.kind} ${event.agent} ${event.detail}`).join('\n'),
  );

  console.log('\nDescription:');
  console.log(task.description.split('\n').slice(0, DESCRIPTION_LINE_LIMIT).join('\n'));
}

export function runBoardCommand(args, dbPath) {
  if (args[0] === '--task') {
    renderTaskCard(openReadOnlyDatabase(dbPath), Number(args[1]));
    return;
  }

  if (args[0] === '--json') {
    const database = openReadOnlyDatabase(dbPath);
    console.log(JSON.stringify({ tasks: fetchBoardTasks(database) }));
    database.close();
    return;
  }

  // Default: serve the web board. `board`, `board 4600`, `board --serve
  // [port]` (kept as an alias) all land here.
  const portArgument = args[0] === '--serve' ? args[1] : args[0];
  const port = portArgument ? Number(portArgument) : undefined;
  if (portArgument !== undefined && !Number.isInteger(port)) {
    console.error('usage: crm.mjs board [port] | board --json | board --task ID');
    process.exit(1);
  }
  import('./boardWeb.mjs').then(({ serveBoard }) => serveBoard(dbPath, port));
}
