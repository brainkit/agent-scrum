#!/usr/bin/env node
// Single Node CLI for the whole Scrum-CRM mechanics. Every
// scrum_crm/*.sh is now a thin shim exec'ing `node crm.mjs <cmd> "$@"` —
// this file (plus lib/*.mjs) is the one source of truth for the mechanics,
// cross-platform (Windows-native, no bash-isms except the test-runner and
// git shell-outs, which are the deliberate exception).
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { statSync } from 'node:fs';
import { checkNodeVersion, formatNodeVersionError } from './lib/nodeVersion.mjs';

// Gate before any static/dynamic import of db.mjs/board.mjs (node:sqlite):
// a static import of those on Node <22.5 throws Node's own cryptic
// ERR_UNKNOWN_BUILTIN_MODULE instead of this readable message, so the
// sqlite-dependent libs are loaded lazily in loadLibs(), after this check.
if (!checkNodeVersion(process.versions.node)) {
  process.stderr.write(`${formatNodeVersionError(process.versions.node)}\n`);
  process.exit(1);
}

// node:sqlite (pulled in by lib/db.mjs below) still emits an
// ExperimentalWarning on every run; it's noise for a CLI whose sqlite usage
// is a deliberate, stable choice here, not an experiment being evaluated.
// Installed before any dynamic import so it's in place when db.mjs loads
// node:sqlite. Only the SQLite warning is swallowed — anything else still
// goes to originalEmitWarning unchanged.
const originalEmitWarning = process.emitWarning.bind(process);
process.emitWarning = (warning, ...rest) => {
  const message = typeof warning === 'string' ? warning : warning?.message;
  const isSqliteExperimentalWarning =
    typeof message === 'string' &&
    (message.includes('SQLite') || message.includes('ExperimentalWarning: SQLite'));
  if (isSqliteExperimentalWarning) {
    return;
  }
  originalEmitWarning(warning, ...rest);
};

let runInit, runQuery, scalarFromRows;
let loadConfig;
let claim, insertEvent, sweepStaleLeases;
let fastOpen, fastClose, batchOpen, batchClose;
let snapshot, restoreSnapshot;
let runTests;
let runBoardCommand;
let collectReport, formatReport;
let advanceTask, batchClaim, batchAdvance, returnTask, releaseTask, addTask, addFiles, addDep, appendDescription, setHint, setPriority, setSummary;

async function loadLibs() {
  ({ advanceTask, batchClaim, batchAdvance, returnTask, releaseTask, addTask, addFiles, addDep, appendDescription, setHint, setPriority, setSummary } = await import(
    './lib/writeOps.mjs'
  ));
  ({ runInit, runQuery, scalarFromRows } = await import('./lib/db.mjs'));
  ({ loadConfig } = await import('./lib/config.mjs'));
  ({ claim, insertEvent, sweepStaleLeases } = await import('./lib/claimEventSweep.mjs'));
  ({ fastOpen, fastClose, batchOpen, batchClose } = await import('./lib/openClose.mjs'));
  ({ snapshot, restoreSnapshot } = await import('./lib/snapshot.mjs'));
  ({ runTests } = await import('./lib/testRunner.mjs'));
  ({ runBoardCommand } = await import('./lib/board.mjs'));
  ({ collectReport, formatReport } = await import('./lib/report.mjs'));
}

const CRM_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = dirname(CRM_DIR);
const DB_PATH = join(CRM_DIR, 'crm.db');
const INIT_SQL_PATH = join(CRM_DIR, 'init.sql');

function fail(message, exitCode = 1) {
  process.stderr.write(`${message}\n`);
  process.exit(exitCode);
}

function doInit() {
  runInit(DB_PATH, INIT_SQL_PATH);
  process.stdout.write('[]');
}

const READ_ONLY_SQL_PREFIXES = ['SELECT', 'WITH', 'PRAGMA', 'EXPLAIN'];

function isReadOnlySql(sql) {
  const firstKeyword = String(sql || '')
    .replace(/^\s*(--[^\n]*\n\s*)*/, '')
    .trimStart()
    .split(/[\s(]/, 1)[0]
    .toUpperCase();
  return READ_ONLY_SQL_PREFIXES.includes(firstKeyword);
}

function runDbCommand(args) {
  try {
    if (args[0] === '--init') {
      doInit();
      return;
    }

    const flags = [];
    while (args[0] === '--scalar' || args[0] === '--unsafe-write') {
      flags.push(args.shift());
    }
    const isScalarMode = flags.includes('--scalar');
    const allowWrite = flags.includes('--unsafe-write');
    const sql = args[0];
    const params = args.slice(1);

    if (!allowWrite && !isReadOnlySql(sql)) {
      fail(
        'db is read-only for agents (SELECT/WITH/PRAGMA/EXPLAIN). Writes go through the ' +
          'sanctioned subcommands: claim, batch-claim, fast-open/fast-close, batch-open/batch-close, ' +
          'advance, batch-advance, return, release, add-task, add-files, add-dep, append-desc, set-hint, event. ' +
          'Humans may force raw SQL with: crm.mjs db --unsafe-write "SQL".',
        4,
      );
    }

    const rows = runQuery(DB_PATH, sql, params);

    if (isScalarMode) {
      const scalar = scalarFromRows(rows);
      process.stdout.write(scalar === undefined ? '' : scalar);
    } else {
      process.stdout.write(JSON.stringify(rows));
    }
  } catch (error) {
    process.stderr.write(JSON.stringify({ error: error.message }));
    process.exit(1);
  }
}

function runClaimCommand(args) {
  const role = args[0];
  if (!['plan', 'dev', 'review', 'qa', 'doc'].includes(role)) {
    fail('usage: crm.mjs claim plan|dev|review|qa|doc');
  }
  const config = loadConfig(CRM_DIR);
  const claimed = claim(role, DB_PATH, { leaseMinutes: config.leaseMinutes, abandonMinutes: config.abandonMinutes, crmDir: CRM_DIR, projectRoot: PROJECT_ROOT });
  if (claimed) {
    process.stdout.write(`${claimed.id} ${claimed.agent}\n`);
  }
}

function runEventCommand(args) {
  if (args.length < 4) {
    fail('usage: crm.mjs event TASK_ID AGENT KIND "detail"');
  }
  const [taskId, agent, kind, detail] = args;
  try {
    insertEvent(DB_PATH, taskId, agent, kind, detail);
  } catch {
    fail(`crm.mjs event: failed to insert event for task ${taskId}`);
  }
}

function runFastOpenCommand(args) {
  if (args.length < 3) {
    fail('usage: crm.mjs fast-open TITLE DESCRIPTION FILE1 [FILE2 ...]');
  }
  const [title, description, ...files] = args;
  try {
    const { id, agent } = fastOpen({ title, description, files, dbPath: DB_PATH });
    process.stdout.write(`${id} ${agent}\n`);
  } catch (error) {
    fail(error.message);
  }
}

function runFastCloseCommand(args) {
  const [taskId, agent] = args;
  if (!taskId || !agent) {
    fail('usage: crm.mjs fast-close ID AGENT');
  }
  const config = loadConfig(CRM_DIR);
  try {
    const summary = fastClose({ taskId, agent, dbPath: DB_PATH, crmDir: CRM_DIR, projectRoot: PROJECT_ROOT, config });
    process.stdout.write(`${summary}\n`);
  } catch (error) {
    fail(error.message);
  }
}

function runBatchOpenCommand(args) {
  const specPath = args[0];
  if (!specPath) {
    fail('usage: crm.mjs batch-open SPEC.json');
  }
  try {
    const indexToId = batchOpen({ specPath, dbPath: DB_PATH, projectRoot: PROJECT_ROOT, config: loadConfig(CRM_DIR) });
    indexToId.forEach((taskId, index) => process.stdout.write(`${index}\t${taskId}\n`));
  } catch (error) {
    process.stderr.write(JSON.stringify({ error: error.message }) + '\n');
    process.exit(1);
  }
}

function runBatchCloseCommand(args) {
  if (args.length < 1) {
    fail('usage: crm.mjs batch-close ID [ID...]');
  }
  const config = loadConfig(CRM_DIR);
  const result = batchClose({ taskIds: args, dbPath: DB_PATH, crmDir: CRM_DIR, projectRoot: PROJECT_ROOT, config });
  for (const line of result.lines) {
    const stream = line.stream === 'stderr' ? process.stderr : process.stdout;
    stream.write(`${line.text}\n`);
  }
  process.exit(result.exitCode);
}

function runSnapshotCommand(args) {
  const taskId = args[0];
  if (!taskId) {
    fail('usage: crm.mjs snapshot TASK_ID');
  }
  snapshot({ taskId, dbPath: DB_PATH, crmDir: CRM_DIR, projectRoot: PROJECT_ROOT });
}

function runRestoreCommand(args) {
  const taskId = args[0];
  if (!taskId) {
    fail('usage: crm.mjs restore TASK_ID');
  }
  restoreSnapshot({ taskId, crmDir: CRM_DIR, projectRoot: PROJECT_ROOT });
}

function runSweepCommand(args) {
  const minutes = args[0] ? Number(args[0]) : 30;
  const sweepConfig = loadConfig(CRM_DIR);
  const messages = sweepStaleLeases({ minutes, abandonMinutes: sweepConfig.abandonMinutes, dbPath: DB_PATH, crmDir: CRM_DIR, projectRoot: PROJECT_ROOT });
  for (const message of messages) {
    process.stdout.write(`${message}\n`);
  }
}

function runRunTestsCommand(args) {
  const target = args[0];
  if (!target) {
    fail('usage: crm.mjs run-tests TASK_ID|all');
  }
  const config = loadConfig(CRM_DIR);
  const result = runTests({ target, crmDir: CRM_DIR, projectRoot: PROJECT_ROOT, config });
  process.stdout.write(`${result.logPath}\n`);
  process.exit(result.exitCode);
}

function runContextFitCommand(args) {
  const files = [];
  let extraTokens = 0;
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === '--extra-tokens') {
      extraTokens = Number(args[i + 1]) || 0;
      i += 1;
      continue;
    }
    files.push(args[i]);
  }
  if (files.length === 0) {
    fail('usage: crm.mjs context-fit FILE... [--extra-tokens N]');
  }

  let totalBytes = 0;
  for (const file of files) {
    try {
      totalBytes += statSync(file).size;
    } catch {
      process.stderr.write(`context-fit: warning: cannot read ${file}, skipping\n`);
    }
  }

  const config = loadConfig(CRM_DIR);
  const windowTokens = config.contextWindowTokens ?? 200000;
  const fitThreshold = config.contextFitThreshold ?? 0.6;
  const estTokens = Math.ceil(totalBytes / 4) + extraTokens;
  const ratio = estTokens / windowTokens;
  const verdict = ratio > fitThreshold ? 'exceeds' : 'fits';

  process.stdout.write(
    `context-fit: ${estTokens} tokens of ${windowTokens} (${(ratio * 100).toFixed(1)}%), ` +
      `threshold ${(fitThreshold * 100).toFixed(1)}% -> ${verdict}\n`
  );
  process.exit(verdict === 'exceeds' ? 3 : 0);
}

function takeFlag(args, name) {
  const index = args.indexOf(name);
  if (index === -1) return undefined;
  const value = args[index + 1];
  args.splice(index, 2);
  return value;
}

function takeBoolFlag(args, name) {
  const index = args.indexOf(name);
  if (index === -1) return false;
  args.splice(index, 1);
  return true;
}

function runAdvanceCommand(args) {
  const rest = [...args];
  const guardAgent = takeFlag(rest, '--agent');
  const claimAgent = takeFlag(rest, '--claim');
  const hint = takeFlag(rest, '--hint');
  const release = takeBoolFlag(rest, '--release');
  const [taskIdRaw, status] = rest;
  if (!taskIdRaw || !status) {
    fail('usage: crm.mjs advance ID STATUS [--agent A] [--claim A] [--release] [--hint TEXT; required for BLOCKED]');
  }
  try {
    advanceTask({ dbPath: DB_PATH, taskId: Number(taskIdRaw), status, guardAgent, claimAgent, release, hint });
    process.stdout.write(`${taskIdRaw} ${status}\n`);
  } catch (error) {
    fail(error.message);
  }
}

function parseBatchIds(rawIds, usage) {
  if (rawIds.length === 0) {
    fail(usage);
  }
  const taskIds = rawIds.map(Number);
  if (taskIds.some((id) => !Number.isInteger(id) || id <= 0)) {
    fail(usage);
  }
  return taskIds;
}

function runBatchClaimCommand(args) {
  const rest = [...args];
  const agent = takeFlag(rest, '--agent');
  const taskIds = parseBatchIds(rest, 'usage: crm.mjs batch-claim ID [ID...] [--agent NAME]');
  try {
    const result = batchClaim({ dbPath: DB_PATH, taskIds, agent });
    process.stdout.write(`${result.agent} ${result.taskIds.join(' ')}\n`);
  } catch (error) {
    fail(error.message);
  }
}

function runBatchAdvanceCommand(args) {
  const rest = [...args];
  const guardAgent = takeFlag(rest, '--agent');
  const release = takeBoolFlag(rest, '--release');
  const status = rest.pop();
  const usage = 'usage: crm.mjs batch-advance ID [ID...] STATUS [--agent A] [--release]';
  if (!status || /^[0-9]+$/.test(status)) {
    fail(usage);
  }
  const taskIds = parseBatchIds(rest, usage);
  try {
    batchAdvance({ dbPath: DB_PATH, taskIds, status, guardAgent, release });
    process.stdout.write(`${taskIds.join(' ')} ${status}\n`);
  } catch (error) {
    fail(error.message);
  }
}

function runReturnCommand(args) {
  const rest = [...args];
  const logPath = takeFlag(rest, '--log');
  const hint = takeFlag(rest, '--hint');
  const guardAgent = takeFlag(rest, '--agent');
  const byName = takeFlag(rest, '--by');
  const [taskIdRaw] = rest;
  if (!taskIdRaw || !logPath) {
    fail('usage: crm.mjs return ID --log PATH [--hint TEXT] [--agent A] [--by NAME]');
  }
  try {
    returnTask({ dbPath: DB_PATH, taskId: Number(taskIdRaw), logPath, hint, guardAgent, byName });
    process.stdout.write(`${taskIdRaw} READY_FOR_DEV\n`);
  } catch (error) {
    fail(error.message);
  }
}

function runReleaseCommand(args) {
  const [taskIdRaw, agent] = args;
  if (!taskIdRaw || !agent) {
    fail('usage: crm.mjs release ID AGENT');
  }
  try {
    releaseTask({ dbPath: DB_PATH, taskId: Number(taskIdRaw), agent });
    process.stdout.write(`${taskIdRaw} released\n`);
  } catch (error) {
    fail(error.message);
  }
}

function runAddTaskCommand(args) {
  const rest = [...args];
  const priority = takeFlag(rest, '--priority');
  const status = takeFlag(rest, '--status');
  const [title, description] = rest;
  if (!title || !description) {
    fail('usage: crm.mjs add-task TITLE DESCRIPTION [--priority N] [--status PLANNING|READY_FOR_DEV]');
  }
  try {
    const id = addTask({ dbPath: DB_PATH, title, description, priority: priority ? Number(priority) : undefined, status });
    process.stdout.write(`${id}\n`);
  } catch (error) {
    fail(error.message);
  }
}

function runAddFilesCommand(args) {
  const [taskIdRaw, ...paths] = args;
  if (!taskIdRaw || paths.length === 0) {
    fail('usage: crm.mjs add-files ID PATH [PATH...]');
  }
  try {
    addFiles({ dbPath: DB_PATH, taskId: Number(taskIdRaw), paths });
  } catch (error) {
    fail(error.message);
  }
}

function runAddDepCommand(args) {
  const [taskIdRaw, depIdRaw] = args;
  if (!taskIdRaw || !depIdRaw) {
    fail('usage: crm.mjs add-dep ID DEPENDS_ON_ID');
  }
  try {
    addDep({ dbPath: DB_PATH, taskId: Number(taskIdRaw), dependsOnId: Number(depIdRaw) });
  } catch (error) {
    fail(error.message);
  }
}

function runAppendDescCommand(args) {
  const [taskIdRaw, text] = args;
  if (!taskIdRaw || !text) {
    fail('usage: crm.mjs append-desc ID TEXT');
  }
  try {
    appendDescription({ dbPath: DB_PATH, taskId: Number(taskIdRaw), text });
  } catch (error) {
    fail(error.message);
  }
}

function runSetPriorityCommand(args) {
  const [taskIdRaw, priorityRaw] = args;
  if (!taskIdRaw || priorityRaw === undefined) {
    fail('usage: crm.mjs set-priority ID N');
  }
  try {
    setPriority({ dbPath: DB_PATH, taskId: Number(taskIdRaw), priority: Number(priorityRaw) });
  } catch (error) {
    fail(error.message);
  }
}

function runSetHintCommand(args) {
  const [taskIdRaw, hint] = args;
  if (!taskIdRaw || hint === undefined) {
    fail('usage: crm.mjs set-hint ID TEXT');
  }
  try {
    setHint({ dbPath: DB_PATH, taskId: Number(taskIdRaw), hint });
  } catch (error) {
    fail(error.message);
  }
}

// report [DAYS] [--json] — the mechanics ledger (see lib/report.mjs).
function runReportCommand(args) {
  const rest = [...args];
  const asJson = takeBoolFlag(rest, '--json');
  const days = rest[0] ? Number(rest[0]) : 30;
  if (!Number.isFinite(days) || days <= 0) {
    fail('usage: crm.mjs report [DAYS] [--json]');
  }
  const report = collectReport({ dbPath: DB_PATH, days });
  process.stdout.write(asJson ? `${JSON.stringify(report)}\n` : `${formatReport(report)}\n`);
}

function runSetSummaryCommand(args) {
  const rest = [...args];
  const guardAgent = takeFlag(rest, '--agent');
  const [taskIdRaw, summary] = rest;
  if (!taskIdRaw || summary === undefined) {
    fail('usage: crm.mjs set-summary ID "what was done" [--agent A]');
  }
  try {
    setSummary({ dbPath: DB_PATH, taskId: Number(taskIdRaw), summary, guardAgent });
    process.stdout.write(`${taskIdRaw} summary set\n`);
  } catch (error) {
    fail(error.message);
  }
}

const COMMANDS = {
  init: () => doInit(),
  db: runDbCommand,
  advance: runAdvanceCommand,
  'batch-claim': runBatchClaimCommand,
  'batch-advance': runBatchAdvanceCommand,
  return: runReturnCommand,
  release: runReleaseCommand,
  'add-task': runAddTaskCommand,
  'add-files': runAddFilesCommand,
  'add-dep': runAddDepCommand,
  'append-desc': runAppendDescCommand,
  'set-hint': runSetHintCommand,
  'set-summary': runSetSummaryCommand,
  'set-priority': runSetPriorityCommand,
  claim: runClaimCommand,
  event: runEventCommand,
  'fast-open': runFastOpenCommand,
  'fast-close': runFastCloseCommand,
  'batch-open': runBatchOpenCommand,
  'batch-close': runBatchCloseCommand,
  board: (args) => runBoardCommand(args, DB_PATH),
  report: runReportCommand,
  snapshot: runSnapshotCommand,
  restore: runRestoreCommand,
  sweep: runSweepCommand,
  'run-tests': runRunTestsCommand,
  'context-fit': runContextFitCommand,
};

async function main() {
  await loadLibs();
  const [command, ...args] = process.argv.slice(2);
  const handler = COMMANDS[command];
  if (!handler) {
    fail(`usage: crm.mjs <${Object.keys(COMMANDS).join('|')}> [...args]`);
  }
  handler(args);
}

main();
