// `report` — the mechanics ledger: what the guarantees actually did on
// this project. Every number comes from the DB (events written by the
// mechanics themselves, task rows), never from an agent's account of its
// own work, so the value of the process can be counted instead of argued.
import { runQuery } from './db.mjs';

const DEFAULT_WINDOW_DAYS = 30;

function scalar(dbPath, sql, params = []) {
  const rows = runQuery(dbPath, sql, params);
  const value = rows.length === 0 ? 0 : Object.values(rows[0])[0];
  return Number(value ?? 0);
}

export function collectReport({ dbPath, days = DEFAULT_WINDOW_DAYS }) {
  const since = `-${Number(days)} days`;
  const windowClause = "created_at >= datetime('now', ?)";

  const prevented = {
    dodGateBlocks: scalar(
      dbPath,
      `SELECT COUNT(*) FROM events WHERE kind='blocker' AND (detail LIKE 'Definition of Done red%' OR detail LIKE 'DoD gate red%') AND ${windowClause}`,
      [since],
    ),
    illegalTransitions: scalar(
      dbPath,
      `SELECT COUNT(*) FROM events WHERE kind='refusal' AND detail LIKE '%Invalid status transition%' AND ${windowClause}`,
      [since],
    ),
    blockedWithoutReason: scalar(
      dbPath,
      `SELECT COUNT(*) FROM events WHERE kind='refusal' AND detail LIKE '%BLOCKED%reason%' AND ${windowClause}`,
      [since],
    ),
    schemaGateRejections: scalar(
      dbPath,
      `SELECT COUNT(*) FROM events WHERE kind='refusal' AND detail LIKE 'schema gate%' AND ${windowClause}`,
      [since],
    ),
    planRefusals: scalar(
      dbPath,
      `SELECT COUNT(*) FROM events WHERE kind='refusal' AND detail LIKE 'PLAN refused%' AND ${windowClause}`,
      [since],
    ),
    otherRefusals: scalar(
      dbPath,
      `SELECT COUNT(*) FROM events WHERE kind='refusal' AND ${windowClause}
         AND detail NOT LIKE '%Invalid status transition%'
         AND detail NOT LIKE '%BLOCKED%reason%'
         AND detail NOT LIKE 'schema gate%'
         AND detail NOT LIKE 'PLAN refused%'`,
      [since],
    ),
    deadHolderSweeps: scalar(dbPath, `SELECT COUNT(*) FROM events WHERE kind='sweep' AND ${windowClause}`, [since]),
  };
  prevented.total = Object.values(prevented).reduce((sum, value) => sum + value, 0);

  const rework = {
    returns: scalar(dbPath, `SELECT COUNT(*) FROM events WHERE kind='handoff' AND detail LIKE 'returned%' AND ${windowClause}`, [since]),
    tasksReturnedAtLeastOnce: scalar(dbPath, 'SELECT COUNT(*) FROM tasks WHERE loop_count > 0'),
    escalatedToBlocked: scalar(dbPath, `SELECT COUNT(*) FROM events WHERE kind='blocker' AND detail LIKE 'blocked:%' AND ${windowClause}`, [since]),
  };

  const throughput = {
    done: scalar(dbPath, "SELECT COUNT(*) FROM tasks WHERE status='DONE'"),
    inFlight: scalar(dbPath, "SELECT COUNT(*) FROM tasks WHERE status NOT IN ('DONE','CANCELLED','BACKLOG')"),
    backlog: scalar(dbPath, "SELECT COUNT(*) FROM tasks WHERE status='BACKLOG'"),
    blockedNow: scalar(dbPath, "SELECT COUNT(*) FROM tasks WHERE status='BLOCKED'"),
  };

  const audit = {
    events: scalar(dbPath, `SELECT COUNT(*) FROM events WHERE ${windowClause}`, [since]),
    statusTransitions: scalar(dbPath, `SELECT COUNT(*) FROM events WHERE kind='status' AND ${windowClause}`, [since]),
    decisionsLogged: scalar(dbPath, `SELECT COUNT(*) FROM events WHERE kind='decision' AND ${windowClause}`, [since]),
  };

  return { windowDays: Number(days), prevented, rework, throughput, audit };
}

function line(label, value) {
  return `  ${label.padEnd(58, '.')} ${String(value).padStart(5)}`;
}

export function formatReport(report) {
  const { prevented, rework, throughput, audit } = report;
  return [
    `Agent Scrum — mechanics ledger (last ${report.windowDays} days)`,
    '',
    'Silent failures prevented (each would have passed unnoticed)',
    line('closes blocked on red or missing tests (Definition of Done)', prevented.dodGateBlocks),
    line('illegal status transitions refused', prevented.illegalTransitions),
    line('BLOCKED without a stated reason refused', prevented.blockedWithoutReason),
    line('tasks refused without Given/When/Then or files', prevented.schemaGateRejections),
    line('PLAN refused (planMode=off)', prevented.planRefusals),
    line('other guarded-write refusals', prevented.otherRefusals),
    line('dead-holder claims swept back to their queues', prevented.deadHolderSweeps),
    line('TOTAL', prevented.total),
    '',
    'Rework caught by the process',
    line('tasks returned for rework', rework.returns),
    line('tasks that needed at least one return (all time)', rework.tasksReturnedAtLeastOnce),
    line('escalations to BLOCKED', rework.escalatedToBlocked),
    '',
    'Throughput (all time)',
    line('DONE', throughput.done),
    line('in flight', throughput.inFlight),
    line('backlog', throughput.backlog),
    line('blocked now', throughput.blockedNow),
    '',
    'Audit trail',
    line('events recorded', audit.events),
    line('  of them status transitions (logged by trigger)', audit.statusTransitions),
    line('  of them agent decisions', audit.decisionsLogged),
    '',
    prevented.total === 0
      ? 'No refusals in this window: nothing tried to skip the process — the guarantees cost you nothing here.'
      : `The mechanics refused ${prevented.total} operation(s) in this window; each is a step that would otherwise have passed silently.`,
  ].join('\n');
}
