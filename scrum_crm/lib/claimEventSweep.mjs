// claim(role) / insertEvent(...) / sweepStaleLeases(minutes) — ported from
// claim.sh, event.sh, lease_sweep.sh.
import { hostname } from 'node:os';
import { runQuery, runScalar } from './db.mjs';
import { restoreSnapshot } from './snapshot.mjs';
import { captureHolder, isHolderAlive } from './liveness.mjs';

const CLAIM_QUERIES = {
  plan: `
    UPDATE tasks SET status='PLANNING', assigned_agent=?, locked_at=datetime('now'), holder_pid=?, holder_start=?
    WHERE id=(SELECT id FROM tasks WHERE status='BACKLOG' AND assigned_agent IS NULL
              ORDER BY priority DESC, id ASC LIMIT 1)
    RETURNING id;`,
  dev: `
    UPDATE tasks SET status='CODING', assigned_agent = ?, locked_at = datetime('now'), holder_pid = ?, holder_start = ?
    WHERE id = (
      SELECT t.id FROM tasks t
      WHERE t.status = 'READY_FOR_DEV' AND t.assigned_agent IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM task_deps d JOIN tasks p ON p.id = d.depends_on_id
          WHERE d.task_id = t.id AND p.status NOT IN ('READY_FOR_DOCS','DOCUMENTING','DONE','CANCELLED'))
        AND NOT EXISTS (
          SELECT 1 FROM task_files f1
          JOIN task_files f2 ON f2.path = f1.path AND f2.task_id <> t.id
          JOIN tasks o ON o.id = f2.task_id
          WHERE f1.task_id = t.id
            AND o.status IN ('CODING','READY_FOR_REVIEW','REVIEWING','READY_FOR_TEST','TESTING','READY_FOR_DOCS','DOCUMENTING'))
      ORDER BY t.priority DESC, t.id ASC LIMIT 1)
    RETURNING id;`,
  review: `
    UPDATE tasks SET status='REVIEWING', assigned_agent=?, locked_at=datetime('now'), holder_pid=?, holder_start=?
    WHERE id=(SELECT id FROM tasks WHERE status='READY_FOR_REVIEW' AND assigned_agent IS NULL
              ORDER BY priority DESC, id ASC LIMIT 1)
    RETURNING id;`,
  qa: `
    UPDATE tasks SET status='TESTING', assigned_agent=?, locked_at=datetime('now'), holder_pid=?, holder_start=?
    WHERE id=(SELECT id FROM tasks WHERE status='READY_FOR_TEST' AND assigned_agent IS NULL
              ORDER BY priority DESC, id ASC LIMIT 1)
    RETURNING id;`,
  doc: `
    UPDATE tasks SET status='DOCUMENTING', assigned_agent=?, locked_at=datetime('now'), holder_pid=?, holder_start=?
    WHERE id=(SELECT id FROM tasks WHERE status='READY_FOR_DOCS' AND assigned_agent IS NULL
              ORDER BY priority DESC, id ASC LIMIT 1)
    RETURNING id;`,
};

export function hostnameShort() {
  return hostname().split('.')[0];
}

export function claim(role, dbPath, options = {}) {
  const query = CLAIM_QUERIES[role];
  if (!query) {
    throw new Error('usage: claim dev|review|qa|doc');
  }

  // Self-healing queues: stale leases (a crashed/interrupted agent) are
  // released before every claim, so an in-progress status only ever shows
  // work that is actually alive within the lease window.
  const leaseMinutes = options.leaseMinutes ?? 30;
  const sweepMessages = sweepStaleLeases({
    minutes: leaseMinutes,
    abandonMinutes: options.abandonMinutes,
    dbPath,
    crmDir: options.crmDir,
    projectRoot: options.projectRoot,
  });
  for (const message of sweepMessages) {
    process.stderr.write(`${message}\n`);
  }

  const agent = `${role}_${hostnameShort()}_${process.pid}`;
  const holder = captureHolder();
  const claimedId = runScalar(dbPath, query, [agent, holder?.pid ?? null, holder?.start ?? null]);
  return claimedId ? { id: claimedId, agent } : null;
}

export function insertEvent(dbPath, taskId, agent, kind, detail) {
  runQuery(dbPath, 'INSERT INTO events (task_id, agent, kind, detail) VALUES (?,?,?,?)', [taskId, agent, kind, detail]);
}

// Mechanics ledger: every refusal the system makes is recorded, so the
// value of the guarantees can be counted later instead of argued about.
// Best-effort — a failed ledger write must never mask the refusal itself.
export function logRefusal(dbPath, taskId, agent, detail) {
  try {
    insertEvent(dbPath, taskId, agent, 'refusal', detail);
  } catch {
    /* the refusal is still reported to the caller */
  }
}

// A claim is dead when its holder SESSION is verifiably gone (pid absent,
// or pid reused — start time mismatch). A verifiably alive holder is never
// swept, however old the claim. Rows without holder info (legacy claims,
// no /proc) fall back to the leaseMinutes age check.
export function claimIsDead(row, minutes) {
  const alive = isHolderAlive(row.holder_pid, row.holder_start);
  if (alive === true) {
    return false;
  }
  if (alive === false) {
    return true;
  }
  return row.age_minutes !== null && row.age_minutes >= minutes;
}

function staleTaskIds(dbPath, statusClauseSql, minutes) {
  const rows = runQuery(
    dbPath,
    `SELECT id, holder_pid, holder_start,
            CAST((julianday('now') - julianday(locked_at)) * 1440 AS INTEGER) AS age_minutes
     FROM tasks WHERE ${statusClauseSql} AND locked_at IS NOT NULL`,
    [],
  );
  return rows.filter((row) => claimIsDead(row, Number(minutes))).map((row) => row.id);
}

// Where work goes when the session that claimed it walked away. A crash
// returns work to the queue it came from (below); being forgotten is a
// different thing — nobody decided to stop, so the plan itself is stale
// and the task goes back to the BACKLOG for a human to re-plan.
const ABANDON_TARGETS = {
  PLANNING: 'BACKLOG',
  CODING: 'BACKLOG',
  REVIEWING: 'READY_FOR_REVIEW',
  TESTING: 'READY_FOR_TEST',
  DOCUMENTING: 'READY_FOR_DOCS',
};

// Abandonment is about ACTIVITY, not liveness: a chat that claimed a task
// two days ago and moved on is very much alive. Activity is the claim
// itself, anything written to the task's trace, and — through the edit
// guard's heartbeat — every file its holder touches, so a slow worker
// keeps its claim while a forgotten task loses it.
function abandonedTasks(dbPath, minutes) {
  const rows = runQuery(
    dbPath,
    `SELECT t.id, t.status, t.holder_pid, t.holder_start,
            CAST((julianday('now') - julianday(MAX(t.locked_at, COALESCE(
              (SELECT MAX(e.created_at) FROM events e WHERE e.task_id = t.id), t.locked_at)))) * 1440 AS INTEGER) AS idle_minutes
     FROM tasks t
     WHERE t.assigned_agent IS NOT NULL AND t.locked_at IS NOT NULL
       AND t.status IN ('PLANNING','CODING','REVIEWING','TESTING','DOCUMENTING')`,
    [],
  );
  return rows.filter(
    (row) => Number(row.idle_minutes) >= Number(minutes) && isHolderAlive(row.holder_pid, row.holder_start) === true,
  );
}

export function sweepAbandonedClaims({ minutes, dbPath }) {
  const messages = [];
  if (!minutes || Number(minutes) <= 0) {
    return messages;
  }
  for (const row of abandonedTasks(dbPath, minutes)) {
    const target = ABANDON_TARGETS[row.status] || 'BACKLOG';
    const hours = Math.round(Number(row.idle_minutes) / 6) / 10;
    // No snapshot rollback here: unlike a crash mid-write nothing was
    // interrupted, so whatever is on disk is deliberate and throwing it
    // away would be the worse mistake.
    runQuery(
      dbPath,
      'UPDATE tasks SET status=?, assigned_agent=NULL, locked_at=NULL, holder_pid=NULL, holder_start=NULL WHERE id=?',
      [target, row.id],
    );
    insertEvent(dbPath, row.id, 'sweep', 'sweep',
      `abandoned: ${row.status} untouched for ${hours}h by a live session -> ${target}`);
    messages.push(`lease_sweep: task ${row.id} (${row.status}) untouched for ${hours}h -> ${target}`);
  }
  return messages;
}

export function sweepStaleLeases({ minutes, dbPath, crmDir, projectRoot, abandonMinutes }) {
  const messages = sweepAbandonedClaims({ minutes: abandonMinutes, dbPath });

  for (const taskId of staleTaskIds(dbPath, "status='PLANNING'", minutes)) {
    runQuery(dbPath, "UPDATE tasks SET status='BACKLOG', assigned_agent=NULL, locked_at=NULL, holder_pid=NULL, holder_start=NULL WHERE id=?", [taskId]);
    insertEvent(dbPath, taskId, 'sweep', 'sweep', 'PLANNING claim released — holder session gone');
    messages.push(`lease_sweep: task ${taskId} (PLANNING) returned to BACKLOG`);
  }

  for (const taskId of staleTaskIds(dbPath, "status='CODING'", minutes)) {
    restoreSnapshot({ taskId, crmDir, projectRoot });
    runQuery(dbPath, "UPDATE tasks SET status='READY_FOR_DEV', assigned_agent=NULL, locked_at=NULL, holder_pid=NULL, holder_start=NULL WHERE id=?", [taskId]);
    insertEvent(dbPath, taskId, 'sweep', 'sweep', 'CODING claim released — holder session gone');
    messages.push(`lease_sweep: task ${taskId} (CODING) rolled back to READY_FOR_DEV`);
  }

  for (const taskId of staleTaskIds(dbPath, "status='TESTING'", minutes)) {
    runQuery(dbPath, "UPDATE tasks SET status='READY_FOR_TEST', assigned_agent=NULL, locked_at=NULL, holder_pid=NULL, holder_start=NULL WHERE id=?", [taskId]);
    insertEvent(dbPath, taskId, 'sweep', 'sweep', 'TESTING claim released — holder session gone');
    messages.push(`lease_sweep: task ${taskId} (TESTING) returned to READY_FOR_TEST`);
  }

  for (const taskId of staleTaskIds(dbPath, "status='DOCUMENTING'", minutes)) {
    runQuery(dbPath, "UPDATE tasks SET status='READY_FOR_DOCS', assigned_agent=NULL, locked_at=NULL, holder_pid=NULL, holder_start=NULL WHERE id=?", [taskId]);
    insertEvent(dbPath, taskId, 'sweep', 'sweep', 'DOCUMENTING claim released — holder session gone');
    messages.push(`lease_sweep: task ${taskId} (DOCUMENTING) returned to READY_FOR_DOCS`);
  }

  for (const taskId of staleTaskIds(dbPath, "status='REVIEWING'", minutes)) {
    runQuery(dbPath, "UPDATE tasks SET status='READY_FOR_REVIEW', assigned_agent=NULL, locked_at=NULL, holder_pid=NULL, holder_start=NULL WHERE id=?", [taskId]);
    insertEvent(dbPath, taskId, 'sweep', 'sweep', 'REVIEWING claim released — holder session gone');
    messages.push(`lease_sweep: task ${taskId} (REVIEWING) returned to READY_FOR_REVIEW`);
  }

  return messages;
}
