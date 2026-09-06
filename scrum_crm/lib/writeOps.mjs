// Sanctioned write operations — the only write path agents are allowed to
// use (crm.mjs db is read-only for them). Each operation is parameterized,
// guarded, and still validated by the enforce_status_flow trigger; raw SQL
// writes are reserved for humans via `db --unsafe-write`.
import { openDatabase, runQuery, runScalar } from './db.mjs';
import { hostnameShort, insertEvent, logRefusal } from './claimEventSweep.mjs';
import { captureHolder } from './liveness.mjs';

function requireTaskId(value, usage) {
  const taskId = Number(value);
  if (!Number.isInteger(taskId) || taskId <= 0) {
    throw new Error(usage);
  }
  return taskId;
}

// advance ID STATUS [--agent A] [--claim A] [--release] [--hint TEXT]
//  --agent A   guard: only if the task is claimed by A
//  --claim A   atomically claim while advancing (requires unclaimed task)
//  --release   clear assigned_agent/locked_at as part of the same update
//  --hint TEXT set resolution_hint in the same update; REQUIRED for
//              STATUS=BLOCKED (the enforce_blocked_reason trigger backs
//              this up at the DB level)
export function advanceTask({ dbPath, taskId, status, guardAgent, claimAgent, release, hint }) {
  if (claimAgent && (guardAgent || release)) {
    throw new Error('advance: --claim cannot be combined with --agent/--release');
  }
  if (status === 'BLOCKED' && (!hint || hint.trim() === '')) {
    logRefusal(dbPath, taskId, guardAgent || claimAgent || 'advance', 'BLOCKED without a reason refused');
    throw new Error('advance: BLOCKED requires a reason — pass --hint "why the task is blocked"');
  }

  const sets = ['status=?'];
  const params = [status];
  if (hint !== undefined) {
    sets.push('resolution_hint=?');
    params.push(hint);
  }
  if (claimAgent) {
    const holder = captureHolder();
    sets.push("assigned_agent=?", "locked_at=datetime('now')", 'holder_pid=?', 'holder_start=?');
    params.push(claimAgent, holder?.pid ?? null, holder?.start ?? null);
  }
  if (release) {
    sets.push('assigned_agent=NULL', 'locked_at=NULL', 'holder_pid=NULL', 'holder_start=NULL');
  }

  const where = ['id=?'];
  params.push(taskId);
  if (guardAgent) {
    where.push('assigned_agent=?');
    params.push(guardAgent);
  }
  if (claimAgent) {
    where.push('assigned_agent IS NULL');
  }

  const sql = `UPDATE tasks SET ${sets.join(', ')} WHERE ${where.join(' AND ')} RETURNING id`;
  let result;
  try {
    result = runScalar(dbPath, sql, params);
  } catch (error) {
    logRefusal(dbPath, taskId, guardAgent || claimAgent || 'advance', `-> ${status} refused: ${error.message}`);
    throw error;
  }
  if (!result) {
    logRefusal(dbPath, taskId, guardAgent || claimAgent || 'advance', `-> ${status} refused: wrong agent, already claimed, or missing task`);
    throw new Error(`advance: task ${taskId} not updated — wrong agent, already claimed, or missing task`);
  }
  if (status === 'BLOCKED') {
    try {
      insertEvent(dbPath, taskId, guardAgent || claimAgent || 'advance', 'blocker', `blocked: ${hint}`);
    } catch {
      process.stderr.write(`advance: event trace write failed for task ${taskId} (non-fatal)\n`);
    }
  }
  return result;
}

// batch-claim ID [ID...] [--agent NAME] — claim a whole pre-assigned group
// in ONE transaction (PLAN lean / PARALLEL: groups are disjoint by
// construction, so per-id claim atomicity protects nothing there — but
// all-or-nothing across the group does: a single wrong/busy id aborts the
// whole batch and names itself, instead of leaving a half-claimed group).
export function batchClaim({ dbPath, taskIds, agent }) {
  const claimAgent = agent || `dev_${hostnameShort()}_${process.pid}`;
  const database = openDatabase(dbPath);
  try {
    database.exec('BEGIN');
    const holder = captureHolder();
    const statement = database.prepare(
      "UPDATE tasks SET status='CODING', assigned_agent=?, locked_at=datetime('now'), holder_pid=?, holder_start=? WHERE id=? AND status='READY_FOR_DEV' AND assigned_agent IS NULL RETURNING id",
    );
    for (const taskId of taskIds) {
      const rows = statement.all(claimAgent, holder?.pid ?? null, holder?.start ?? null, taskId);
      if (rows.length === 0) {
        database.exec('ROLLBACK');
        throw new Error(`batch-claim: task ${taskId} not claimable (missing, not READY_FOR_DEV, or already claimed) — nothing claimed`);
      }
    }
    database.exec('COMMIT');
  } catch (error) {
    try {
      database.exec('ROLLBACK');
    } catch { /* already rolled back */ }
    throw error;
  } finally {
    database.close();
  }
  return { agent: claimAgent, taskIds };
}

// batch-advance ID [ID...] STATUS [--agent A] [--release] — one transaction,
// each id's transition still checked by the enforce_status_flow trigger;
// any failure rolls the whole batch back and names the id. No --claim here
// (that's batch-claim) and no BLOCKED (a blocker is per-task by nature —
// use advance ID BLOCKED --hint).
export function batchAdvance({ dbPath, taskIds, status, guardAgent, release }) {
  if (status === 'BLOCKED') {
    throw new Error('batch-advance: BLOCKED is per-task — use advance ID BLOCKED --hint "why"');
  }
  const sets = ['status=?'];
  if (release) {
    sets.push('assigned_agent=NULL', 'locked_at=NULL', 'holder_pid=NULL', 'holder_start=NULL');
  }
  const where = ['id=?'];
  if (guardAgent) {
    where.push('assigned_agent=?');
  }
  const sql = `UPDATE tasks SET ${sets.join(', ')} WHERE ${where.join(' AND ')} RETURNING id`;

  const database = openDatabase(dbPath);
  try {
    database.exec('BEGIN');
    const statement = database.prepare(sql);
    for (const taskId of taskIds) {
      const params = guardAgent ? [status, taskId, guardAgent] : [status, taskId];
      let rows;
      try {
        rows = statement.all(...params);
      } catch (error) {
        database.exec('ROLLBACK');
        logRefusal(dbPath, taskId, guardAgent || 'batch_advance', `-> ${status} refused: ${error.message}`);
        throw new Error(`batch-advance: task ${taskId} -> ${status} rejected (${error.message}) — nothing advanced`);
      }
      if (rows.length === 0) {
        database.exec('ROLLBACK');
        throw new Error(`batch-advance: task ${taskId} not updated (wrong agent or missing task) — nothing advanced`);
      }
    }
    database.exec('COMMIT');
  } catch (error) {
    try {
      database.exec('ROLLBACK');
    } catch { /* already rolled back */ }
    throw error;
  } finally {
    database.close();
  }
  return taskIds;
}

// return ID --log PATH [--hint TEXT] [--agent A] [--by NAME]
export function returnTask({ dbPath, taskId, logPath, hint, guardAgent, byName }) {
  const sets = ["status='READY_FOR_DEV'", 'loop_count=loop_count+1', 'error_log_path=?', 'assigned_agent=NULL', 'locked_at=NULL', 'holder_pid=NULL', 'holder_start=NULL'];
  const params = [logPath];
  if (hint !== undefined) {
    sets.push('resolution_hint=?');
    params.push(hint);
  }
  const where = ['id=?'];
  params.push(taskId);
  if (guardAgent) {
    where.push('assigned_agent=?');
    params.push(guardAgent);
  }
  const sql = `UPDATE tasks SET ${sets.join(', ')} WHERE ${where.join(' AND ')} RETURNING id`;
  const result = runScalar(dbPath, sql, params);
  if (!result) {
    throw new Error(`return: task ${taskId} not updated — wrong agent or missing task`);
  }
  try {
    insertEvent(dbPath, taskId, byName || guardAgent || 'return', 'handoff', `returned to READY_FOR_DEV (log: ${logPath})`);
  } catch {
    process.stderr.write(`return: event trace write failed for task ${taskId} (non-fatal)\n`);
  }
  return result;
}

// release ID AGENT — clear the claim, status unchanged.
export function releaseTask({ dbPath, taskId, agent }) {
  const result = runScalar(dbPath, 'UPDATE tasks SET assigned_agent=NULL, locked_at=NULL, holder_pid=NULL, holder_start=NULL WHERE id=? AND assigned_agent=? RETURNING id', [
    taskId,
    agent,
  ]);
  if (!result) {
    throw new Error(`release: task ${taskId} not updated — wrong agent or missing task`);
  }
  return result;
}

function hasGivenWhenThen(description) {
  const lowered = description.toLowerCase();
  return lowered.includes('given') && lowered.includes('when') && lowered.includes('then');
}

// add-task TITLE DESC [--priority N] [--status PLANNING|READY_FOR_DEV]
export function addTask({ dbPath, title, description, priority, status }) {
  if (!hasGivenWhenThen(description)) {
    throw new Error('schema gate: description must contain Given/When/Then acceptance criteria');
  }
  const targetStatus = status || 'BACKLOG';
  if (!['BACKLOG', 'PLANNING', 'READY_FOR_DEV'].includes(targetStatus)) {
    throw new Error('add-task: --status must be BACKLOG, PLANNING or READY_FOR_DEV');
  }
  const id = runScalar(dbPath, 'INSERT INTO tasks (title, description, status, priority) VALUES (?,?,?,?) RETURNING id', [
    title,
    description,
    targetStatus,
    priority ?? 5,
  ]);
  if (!id) {
    throw new Error('add-task: failed to insert task');
  }
  return id;
}

export function addFiles({ dbPath, taskId, paths }) {
  if (paths.length === 0) {
    throw new Error('add-files: at least one path required');
  }
  for (const path of paths) {
    runQuery(dbPath, 'INSERT OR IGNORE INTO task_files (task_id, path) VALUES (?,?)', [taskId, path]);
  }
}

// add-dep ID DEP_ID — with the cycle check built in (previously a prompt
// instruction for team-lead; now mechanical).
export function addDep({ dbPath, taskId, dependsOnId }) {
  if (taskId === dependsOnId) {
    throw new Error('add-dep: a task cannot depend on itself');
  }
  const cycle = runScalar(
    dbPath,
    `WITH RECURSIVE reach(id) AS (
       SELECT CAST(? AS INTEGER)
       UNION SELECT d.depends_on_id FROM task_deps d JOIN reach r ON d.task_id = r.id
     ) SELECT 1 FROM reach WHERE id = CAST(? AS INTEGER)`,
    [dependsOnId, taskId],
  );
  if (cycle) {
    throw new Error(`add-dep: dependency ${taskId} -> ${dependsOnId} would create a cycle, rejected`);
  }
  runQuery(dbPath, 'INSERT OR IGNORE INTO task_deps (task_id, depends_on_id) VALUES (?,?)', [taskId, dependsOnId]);
}

export function appendDescription({ dbPath, taskId, text }) {
  const result = runScalar(dbPath, "UPDATE tasks SET description = description || ? WHERE id=? RETURNING id", [`\n${text}`, taskId]);
  if (!result) {
    throw new Error(`append-desc: task ${taskId} not found`);
  }
}

export function setPriority({ dbPath, taskId, priority }) {
  const result = runScalar(dbPath, 'UPDATE tasks SET priority=? WHERE id=? RETURNING id', [priority, taskId]);
  if (!result) {
    throw new Error(`set-priority: task ${taskId} not found`);
  }
}

// set-summary ID TEXT [--agent A] — the task's own short record of what
// was done. Capped, because a summary that grows into a diff stops being
// readable on a board; the full story is in the event trace and the code.
const SUMMARY_MAX_CHARS = 300;

export function setSummary({ dbPath, taskId, summary, guardAgent }) {
  const text = String(summary || '').trim();
  if (text === '') {
    throw new Error('set-summary: the summary must say what was done — empty text refused');
  }
  if (text.length > SUMMARY_MAX_CHARS) {
    throw new Error(`set-summary: keep it to ${SUMMARY_MAX_CHARS} characters (got ${text.length}) — one sentence on the outcome`);
  }
  const where = ['id=?'];
  const params = [text, taskId];
  if (guardAgent) {
    where.push('assigned_agent=?');
    params.push(guardAgent);
  }
  const result = runScalar(dbPath, `UPDATE tasks SET summary=? WHERE ${where.join(' AND ')} RETURNING id`, params);
  if (!result) {
    throw new Error(`set-summary: task ${taskId} not updated — wrong agent or missing task`);
  }
  return result;
}

export function setHint({ dbPath, taskId, hint }) {
  const result = runScalar(dbPath, 'UPDATE tasks SET resolution_hint=? WHERE id=? RETURNING id', [hint, taskId]);
  if (!result) {
    throw new Error(`set-hint: task ${taskId} not found`);
  }
}

export { requireTaskId };
