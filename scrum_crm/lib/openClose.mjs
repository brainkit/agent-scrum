// fast-open/fast-close/batch-open/batch-close — one-call task open/close
// with a schema gate and a DoD (test) gate. Ported from fast_open.sh,
// fast_close.sh, batch_open.mjs, batch_close.sh.
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { openDatabase } from './db.mjs';
import { runQuery, runScalar } from './db.mjs';
import { insertEvent, hostnameShort } from './claimEventSweep.mjs';
import { captureHolder } from './liveness.mjs';
import { runGitAutocommit } from './git.mjs';
import { runTests } from './testRunner.mjs';

function hasGivenWhenThen(description) {
  const lowered = description.toLowerCase();
  return lowered.includes('given') && lowered.includes('when') && lowered.includes('then');
}

export function fastOpen({ title, description, files, dbPath }) {
  if (!hasGivenWhenThen(description)) {
    throw new Error('schema gate: description must contain Given/When/Then acceptance criteria');
  }
  if (files.length === 0) {
    throw new Error('schema gate: task_files empty');
  }

  const id = runScalar(dbPath, "INSERT INTO tasks (title, description, status, priority) VALUES (?,?, 'READY_FOR_DEV', 5) RETURNING id", [
    title,
    description,
  ]);
  if (!id) {
    throw new Error('fast_open: failed to insert task');
  }

  const allFiles = [...files, `tests/task_${id}.test.js`];
  for (const path of allFiles) {
    runQuery(dbPath, 'INSERT INTO task_files (task_id, path) VALUES (?,?)', [id, path]);
  }

  const agent = `fastsolo_${hostnameShort()}_${process.pid}`;
  const holder = captureHolder();
  const claimedId = runScalar(
    dbPath,
    "UPDATE tasks SET status='CODING', assigned_agent=?, locked_at=datetime('now'), holder_pid=?, holder_start=? WHERE id=? AND status='READY_FOR_DEV' AND assigned_agent IS NULL RETURNING id",
    [agent, holder?.pid ?? null, holder?.start ?? null, id],
  );
  if (!claimedId) {
    throw new Error(`fast_open: failed to claim task ${id} (unexpected state)`);
  }

  return { id, agent };
}

function runGuardedStep({ dbPath, stepName, sql, taskId, agent }) {
  const result = runScalar(dbPath, sql, [taskId, agent]);
  if (!result) {
    throw new Error(`fast_close: step '${stepName}' failed for task ${taskId} (agent=${agent}) — agent mismatch, wrong status, or db error`);
  }
}

export function fastClose({ taskId, agent, dbPath, crmDir, projectRoot, config }) {
  if (config.testsEnabled) {
    const dod = runTests({ target: String(taskId), crmDir, projectRoot, config });
    if (dod.exitCode !== 0) {
      try {
        insertEvent(dbPath, taskId, agent, 'blocker', `DoD gate red: ${dod.logPath}`);
      } catch {
        // best-effort trace write, the gate failure itself is already reported below
      }
      throw new Error(`DoD gate: task ${taskId} tests are red (log: ${dod.logPath})`);
    }
  } else {
    process.stderr.write(`fast_close: DoD gate skipped for task ${taskId} (testsEnabled=false)\n`);
  }

  runGuardedStep({ dbPath, stepName: 'READY_FOR_TEST', taskId, agent, sql: "UPDATE tasks SET status='READY_FOR_TEST' WHERE id=? AND assigned_agent=? RETURNING id" });
  runGuardedStep({ dbPath, stepName: 'TESTING', taskId, agent, sql: "UPDATE tasks SET status='TESTING' WHERE id=? AND assigned_agent=? RETURNING id" });
  runGuardedStep({
    dbPath,
    stepName: 'READY_FOR_DOCS',
    taskId,
    agent,
    sql: "UPDATE tasks SET status='READY_FOR_DOCS', error_log_path=NULL WHERE id=? AND assigned_agent=? RETURNING id",
  });
  runGuardedStep({ dbPath, stepName: 'DOCUMENTING', taskId, agent, sql: "UPDATE tasks SET status='DOCUMENTING' WHERE id=? AND assigned_agent=? RETURNING id" });
  runGuardedStep({
    dbPath,
    stepName: 'DONE',
    taskId,
    agent,
    sql: "UPDATE tasks SET status='DONE', assigned_agent=NULL, locked_at=NULL, holder_pid=NULL, holder_start=NULL WHERE id=? AND assigned_agent=? RETURNING id",
  });

  try {
    insertEvent(dbPath, taskId, agent, 'done', 'closed green');
  } catch {
    process.stderr.write(`fast_close: event trace write failed for task ${taskId} (non-fatal)\n`);
  }

  runGitAutocommit({ projectRoot, gitAutocommit: config.gitAutocommit, taskIdsLabel: String(taskId), callerName: 'fast_close' });

  return `DONE ${taskId}`;
}

function loadTickets(specPath) {
  const tickets = JSON.parse(readFileSync(specPath, 'utf8'));
  if (!Array.isArray(tickets)) {
    throw new Error('SPEC.json must be a JSON array of tickets');
  }
  return tickets;
}

function validateTickets(tickets) {
  tickets.forEach((ticket, index) => {
    if (!hasGivenWhenThen(String(ticket.description || ''))) {
      throw new Error(`schema gate: description must contain Given/When/Then acceptance criteria (ticket ${index})`);
    }
    if (!Array.isArray(ticket.files) || ticket.files.length === 0) {
      throw new Error(`schema gate: task_files empty (ticket ${index})`);
    }
  });
}

// Mechanical description extraction: a ticket may carry, instead of an
// inline description, a pointer into the backlog file —
//   "description_from": { "file": "BACKLOG.md", "lines": [12, 19] }
// (1-based, inclusive). batch-open cuts the text out itself, so the full
// ticket lands in the DB (self-contained task, single source of truth)
// without the orchestrator ever retyping it — the model only generates
// 60 pairs of line numbers, not 60 ticket texts.
function resolveDescriptions(tickets, projectRoot) {
  const fileCache = new Map();
  tickets.forEach((ticket, index) => {
    const pointer = ticket.description_from;
    if (!pointer) {
      return;
    }
    if (!pointer.file || !Array.isArray(pointer.lines) || pointer.lines.length !== 2) {
      throw new Error(`ticket ${index}: description_from needs {"file", "lines": [start, end]}`);
    }
    const [startLine, endLine] = pointer.lines.map(Number);
    const absolutePath = resolve(projectRoot, pointer.file);
    if (!fileCache.has(absolutePath)) {
      if (!existsSync(absolutePath)) {
        throw new Error(`ticket ${index}: description_from file not found: ${pointer.file}`);
      }
      fileCache.set(absolutePath, readFileSync(absolutePath, 'utf8').split('\n'));
    }
    const fileLines = fileCache.get(absolutePath);
    if (!Number.isInteger(startLine) || !Number.isInteger(endLine) || startLine < 1 || endLine < startLine || endLine > fileLines.length) {
      throw new Error(`ticket ${index}: description_from lines [${pointer.lines}] out of range (file has ${fileLines.length} lines)`);
    }
    const extracted = fileLines.slice(startLine - 1, endLine).join('\n').trim();
    if (extracted === '') {
      throw new Error(`ticket ${index}: description_from lines [${pointer.lines}] are empty`);
    }
    // A raw backlog rarely phrases tickets as literal Given/When/Then, and
    // the schema gate checks the RESOLVED description. So an inline
    // `description` may accompany the pointer: a one-line G-W-T acceptance
    // summary the model generates cheaply. The two are concatenated —
    // full mechanical text first, summary after — and the gate then holds
    // without anyone retyping the backlog.
    const inlineSummary = String(ticket.description || '').trim();
    ticket.description = inlineSummary === '' ? extracted : `${extracted}\n\n${inlineSummary}`;
  });
}

export function batchOpen({ specPath, dbPath, projectRoot }) {
  const tickets = loadTickets(specPath);
  resolveDescriptions(tickets, projectRoot ?? process.cwd());
  validateTickets(tickets);

  const database = openDatabase(dbPath);
  const insertTask = database.prepare("INSERT INTO tasks (title, description, status, priority) VALUES (?, ?, 'READY_FOR_DEV', 5) RETURNING id");
  const insertFile = database.prepare('INSERT INTO task_files (task_id, path) VALUES (?, ?)');
  const insertDep = database.prepare('INSERT INTO task_deps (task_id, depends_on_id) VALUES (?, ?)');

  database.exec('BEGIN');
  try {
    const indexToId = tickets.map((ticket) => {
      const taskId = insertTask.get(ticket.title, ticket.description).id;
      for (const filePath of ticket.files || []) {
        insertFile.run(taskId, filePath);
      }
      insertFile.run(taskId, `tests/task_${taskId}.test.js`);
      return taskId;
    });

    tickets.forEach((ticket, index) => {
      for (const depIndex of ticket.deps || []) {
        if (!Number.isInteger(depIndex) || depIndex < 0 || depIndex >= indexToId.length) {
          throw new Error(`ticket ${index}: dep index ${depIndex} out of range`);
        }
        insertDep.run(indexToId[index], indexToId[depIndex]);
      }
    });

    database.exec('COMMIT');
    database.close();
    return indexToId;
  } catch (error) {
    database.exec('ROLLBACK');
    database.close();
    throw error;
  }
}

export function batchClose({ taskIds, dbPath, crmDir, projectRoot, config }) {
  const outputLines = [];
  if (config.testsEnabled) {
    const dod = runTests({ target: 'all', crmDir, projectRoot, config });
    if (dod.exitCode !== 0) {
      outputLines.push({ stream: 'stderr', text: `DoD gate: full suite red (log: ${dod.logPath})` });
      for (const taskId of taskIds) {
        try {
          insertEvent(dbPath, taskId, 'batch_close', 'blocker', `DoD gate red: ${dod.logPath}`);
        } catch {
          // best-effort trace write
        }
      }
      return { exitCode: 1, lines: outputLines };
    }
  } else {
    outputLines.push({ stream: 'stderr', text: 'batch_close: DoD gate skipped (testsEnabled=false)' });
  }

  let anySkipped = false;
  const closedIds = [];

  for (const taskId of taskIds) {
    // Executors release at READY_FOR_TEST; a task may also already sit in
    // TESTING (claimed and released by a QA pass) — both are closable.
    runScalar(dbPath, "UPDATE tasks SET status='TESTING' WHERE id=? AND status='READY_FOR_TEST' RETURNING id", [taskId]);
    const step1 = runScalar(dbPath, "UPDATE tasks SET status='READY_FOR_DOCS', error_log_path=NULL WHERE id=? AND status='TESTING' RETURNING id", [taskId]);
    if (!step1) {
      outputLines.push({ stream: 'stderr', text: `batch_close: task ${taskId} skipped — not in READY_FOR_TEST/TESTING` });
      anySkipped = true;
      continue;
    }

    const step2 = runScalar(dbPath, "UPDATE tasks SET status='DOCUMENTING' WHERE id=? AND status='READY_FOR_DOCS' RETURNING id", [taskId]);
    if (!step2) {
      outputLines.push({ stream: 'stderr', text: `batch_close: task ${taskId} stuck at READY_FOR_DOCS -> DOCUMENTING` });
      anySkipped = true;
      continue;
    }

    const step3 = runScalar(dbPath, "UPDATE tasks SET status='DONE', assigned_agent=NULL, locked_at=NULL WHERE id=? AND status='DOCUMENTING' RETURNING id", [taskId]);
    if (!step3) {
      outputLines.push({ stream: 'stderr', text: `batch_close: task ${taskId} stuck at DOCUMENTING -> DONE` });
      anySkipped = true;
      continue;
    }

    try {
      insertEvent(dbPath, taskId, 'batch_close', 'done', 'closed green');
    } catch {
      outputLines.push({ stream: 'stderr', text: `batch_close: event trace write failed for task ${taskId} (non-fatal)` });
    }
    closedIds.push(taskId);
    outputLines.push({ stream: 'stdout', text: `DONE ${taskId}` });
  }

  if (closedIds.length > 0) {
    runGitAutocommit({ projectRoot, gitAutocommit: config.gitAutocommit, taskIdsLabel: closedIds.join(' '), callerName: 'batch_close' });
  }

  return { exitCode: anySkipped ? 2 : 0, lines: outputLines };
}
