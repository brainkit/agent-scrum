#!/usr/bin/env node
// PreToolUse hook (matcher: Write|Edit|MultiEdit|NotebookEdit).
//
// Optional, and off unless `"requireTaskForEdits": true` in
// scrum_crm/config.json: with it on, a session may only change files
// while it HOLDS A CLAIM on a task. That turns "register the work first"
// from a line in a prompt — which a session can simply not follow — into
// a rule the tooling enforces.
//
// The check is the claim itself, never a list of statuses: a claim exists
// exactly while someone is actively working (the developer in CODING, QA
// in TESTING, the doc-writer in DOCUMENTING, a planner in PLANNING), and
// every handoff releases it. So the guard keeps working when the status
// machine gains or renames states — it has no opinion about them.
//
// The claim must belong to THIS session: a task's holder_pid has to be
// one of this hook process's ancestors, because the hook runs as a child
// of the session that claimed it. Another session's claim unlocks
// nothing here.

const fs = require('fs');
const path = require('path');

// Files that must be writable BEFORE any task exists: the backlog and the
// spec are what `batch-open` turns into tasks in the first place, and the
// CRM's own directory is guarded separately by settings.json.
const PLANNING_ARTIFACTS = [/(^|\/)SPEC\d*\.json$/i, /(^|\/)backlog_context\.md$/i, /(^|\/)scrum_crm\//];

function readStdin() {
  return new Promise((resolve) => {
    let input = '';
    process.stdin.on('data', (chunk) => { input += chunk; });
    process.stdin.on('end', () => resolve(input));
    process.stdin.resume();
  });
}

function targetPath(raw) {
  try {
    const payload = JSON.parse(raw);
    const input = payload.tool_input || {};
    return String(input.file_path || input.notebook_path || input.path || '');
  } catch {
    return '';
  }
}

function parentOf(pid) {
  try {
    const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
    return Number(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[1]);
  } catch {
    return null;
  }
}

function ancestorPids() {
  const pids = [];
  let pid = process.pid;
  for (let depth = 0; depth < 12 && pid && pid > 1; depth += 1) {
    pids.push(pid);
    pid = parentOf(pid);
  }
  return pids;
}

async function main() {
  const raw = await readStdin();
  const file = targetPath(raw).split(path.sep).join('/');

  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const crmDir = path.join(projectDir, 'scrum_crm');
  const configPath = path.join(crmDir, 'config.json');
  const dbPath = path.join(crmDir, 'crm.db');

  if (!fs.existsSync(configPath) || !fs.existsSync(dbPath)) {
    process.exit(0);
  }

  let config;
  try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  } catch {
    process.exit(0);
  }

  if (config.requireTaskForEdits !== true) {
    process.exit(0);
  }

  if (file && PLANNING_ARTIFACTS.some((pattern) => pattern.test(file))) {
    process.exit(0);
  }

  let DatabaseSync;
  try {
    ({ DatabaseSync } = require('node:sqlite'));
  } catch {
    process.exit(0); // no sqlite, no opinion
  }

  let claims = [];
  try {
    const database = new DatabaseSync(dbPath);
    claims = database
      .prepare('SELECT id, status, holder_pid FROM tasks WHERE assigned_agent IS NOT NULL AND holder_pid IS NOT NULL')
      .all();
    database.close();
  } catch {
    process.exit(0);
  }

  const ancestors = new Set(ancestorPids());
  if (claims.some((task) => ancestors.has(Number(task.holder_pid)))) {
    process.exit(0);
  }

  process.stderr.write(
    'requireTaskForEdits is on: this session holds no claimed task, so it must not change files.\n' +
      'Open one — node scrum_crm/crm.mjs fast-open "<title>" "<Given/When/Then>" <files...> — or claim an existing one (claim plan|dev|review|qa|doc).\n',
  );
  process.exit(2);
}

main();
