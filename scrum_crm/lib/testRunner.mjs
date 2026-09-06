// Runs the DoD test suite for one task (or the whole suite for "all"),
// writing full stdout+stderr to a log file. Ported from run_tests.sh.
import { spawnSync } from 'node:child_process';
import { closeSync, mkdirSync, openSync } from 'node:fs';
import { join } from 'node:path';
import { substituteTaskId } from './config.mjs';

function utcTimestamp() {
  const now = new Date();
  const pad = (value) => String(value).padStart(2, '0');
  return (
    `${now.getUTCFullYear()}${pad(now.getUTCMonth() + 1)}${pad(now.getUTCDate())}_` +
    `${pad(now.getUTCHours())}${pad(now.getUTCMinutes())}${pad(now.getUTCSeconds())}`
  );
}

// Executes via the platform shell — the one deliberate shell-out in crm.mjs
// (config test commands may be shell syntax, e.g. a `for` loop over globs).
export function runTests({ target, crmDir, projectRoot, config }) {
  const testCommand = target === 'all' ? config.testCmdAll : substituteTaskId(config.testCmdTask, target);

  const logsDir = join(crmDir, 'logs');
  mkdirSync(logsDir, { recursive: true });
  const logPath = join(logsDir, `${target}_${utcTimestamp()}.log`);

  const logFd = openSync(logPath, 'w');
  let exitCode;
  try {
    const result = spawnSync(testCommand, { shell: true, cwd: projectRoot, stdio: ['ignore', logFd, logFd] });
    exitCode = result.status === null ? 1 : result.status;
  } finally {
    closeSync(logFd);
  }

  return { logPath, exitCode };
}
