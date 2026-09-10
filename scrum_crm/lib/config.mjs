// Loads scrum_crm test-runner / conventions / git-autocommit settings from
// config.json (the single source of truth — no config.sh fallback).
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const DEFAULT_CONFIG = {
  testCmdTask: 'npx --no-install jest --runTestsByPath "tests/task_{ID}.test.js"',
  testCmdAll: 'npx --no-install jest',
  conventionsFile: '',
  // PLAN routing: 'auto' (gate decides) | 'ask' (confirm first) | 'off'
  // (never PLAN — batch-open refuses, so it cannot start by accident)
  planMode: 'auto',
  // On by default: a session may only change files while it holds a
  // claim (enforced by claude/hooks/guard_edits.js), so registering the
  // work stops being a prompt rule a session can quietly skip. Set it to
  // false for a repository where agents should be free to edit anything.
  requireTaskForEdits: true,
  intakeEnabled: false,
  reviewEnabled: false,
  testsEnabled: true,
  // Docstrings are written with the code, in every route; this flag is
  // only about a SEPARATE docs stage producing docs/tasks/<id>.md.
  docsEnabled: false,
  gitAutocommit: 'auto',
  leaseMinutes: 30,
  // A live session that has not touched a task for this long has moved on
  // — the claim is released even though the holder is alive. 0 disables.
  abandonMinutes: 480,
  contextWindowTokens: 200000,
  contextFitThreshold: 0.6,
};

export function loadConfig(crmDir) {
  const configJsonPath = join(crmDir, 'config.json');

  if (existsSync(configJsonPath)) {
    return { ...DEFAULT_CONFIG, ...JSON.parse(readFileSync(configJsonPath, 'utf8')) };
  }

  return { ...DEFAULT_CONFIG };
}

export function substituteTaskId(command, taskId) {
  return command.replaceAll('{ID}', taskId);
}
