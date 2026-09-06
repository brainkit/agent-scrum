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
  intakeEnabled: false,
  reviewEnabled: false,
  testsEnabled: true,
  docsEnabled: true,
  gitAutocommit: 'auto',
  leaseMinutes: 30,
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
