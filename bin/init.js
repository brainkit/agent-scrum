#!/usr/bin/env node
// agent-scrum <target-dir> [--force]
// Pure-Node installer (works whether invoked from a local install or via
// `npx agent-scrum`, where __dirname still points at the
// checked-out package): copies scrum_crm/ (excluding crm.db*, logs/,
// snapshots/, __pycache__) and claude/ (as <target>/.claude/) into the
// target project, drops in CLAUDE.md (or CLAUDE.scrum.md if one already
// exists and --force wasn't given), then initializes the target's own DB
// copy.
"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

// Mirrors lib/nodeVersion.mjs's checkNodeVersion/MIN_NODE_* (CommonJS here,
// ESM there — kept as a small duplicate rather than a cross-module-type
// import, so init.js fails fast on its own before touching scrum_crm).
const MIN_NODE_MAJOR = 22;
const MIN_NODE_MINOR = 5;

function checkNodeVersion(versionString) {
  const [major, minor] = versionString.split(".").map(Number);
  if (major > MIN_NODE_MAJOR) {
    return true;
  }
  return major === MIN_NODE_MAJOR && minor >= MIN_NODE_MINOR;
}

if (!checkNodeVersion(process.versions.node)) {
  console.error(
    `agent-scrum requires Node.js >= ${MIN_NODE_MAJOR}.${MIN_NODE_MINOR} (node:sqlite); found v${process.versions.node}`
  );
  process.exit(1);
}

function printUsage() {
  console.log("Agent Scrum — installs the multi-agent Scrum system into a project.");
  console.log("");
  console.log("usage: agent-scrum <target-dir> [--force] [--yes]");
  console.log("");
  console.log("  agent-scrum .             install into the current directory");
  console.log(`                            (${process.cwd()})`);
  console.log("  agent-scrum ~/myproject   install into another project");
  console.log("");
  console.log("  --force   replace an existing CLAUDE.md (default: keep it and add");
  console.log("            CLAUDE.scrum.md plus one @import line)");
  console.log("  --yes     skip the setup questionnaire (intake off, review off,");
  console.log("            tests on, docs on, conventions off)");
  console.log("");
  console.log('Then: cd <target-dir> && claude "your request"');
}

const args = process.argv.slice(2);

if (args.includes("--help") || args.includes("-h")) {
  printUsage();
  process.exit(0);
}

if (args.length === 0) {
  console.error("agent-scrum: a target directory is required — nothing was installed.");
  console.error("");
  printUsage();
  process.exit(1);
}

// --force is a flag, valid in any position; every other "-"-leading arg is
// an unknown option, never a target dir (real incident: `install.sh --force
// /path` created a literal './--force' directory because the first arg was
// blindly taken as the target).
const forceOverwrite = args.includes("--force");
const skipQuestionnaire = args.includes("--yes");
const positionalArgs = args.filter((arg) => arg !== "--force" && arg !== "--yes");
const unknownOption = positionalArgs.find((arg) => arg.startsWith("-"));

if (unknownOption) {
  printUsage();
  console.error(`init.js: unknown option: ${unknownOption}`);
  process.exit(1);
}

if (positionalArgs.length === 0) {
  console.error("agent-scrum: a target directory is required — nothing was installed.");
  console.error("");
  printUsage();
  process.exit(1);
}

const targetDirArg = positionalArgs[0];

const packageRoot = path.join(__dirname, "..");

fs.mkdirSync(targetDirArg, { recursive: true });
const targetDir = fs.realpathSync(targetDirArg);

const SCRUM_CRM_SKIP_NAMES = new Set(["logs", "snapshots", "__pycache__"]);

function shouldSkipScrumCrmEntry(src) {
  const base = path.basename(src);
  return base.startsWith("crm.db") || SCRUM_CRM_SKIP_NAMES.has(base);
}

// An existing scrum_crm/config.json survives upgrades: the user's values
// (test runner, stage toggles, thresholds) win; only NEW default keys from
// the package are merged in. The setup questionnaire is skipped on upgrade.
const targetConfigPath = path.join(targetDir, "scrum_crm", "config.json");
const hostConfigExists = fs.existsSync(targetConfigPath);

console.log(`init.js: copying scrum_crm/ to ${targetDir}`);
fs.mkdirSync(path.join(targetDir, "scrum_crm"), { recursive: true });
fs.cpSync(path.join(packageRoot, "scrum_crm"), path.join(targetDir, "scrum_crm"), {
  recursive: true,
  filter: (src) => !shouldSkipScrumCrmEntry(src) && !(hostConfigExists && path.basename(src) === "config.json"),
});

if (hostConfigExists) {
  const hostConfig = JSON.parse(fs.readFileSync(targetConfigPath, "utf8"));
  const packageConfig = JSON.parse(fs.readFileSync(path.join(packageRoot, "scrum_crm", "config.json"), "utf8"));
  const mergedConfig = { ...packageConfig, ...hostConfig };
  fs.writeFileSync(targetConfigPath, `${JSON.stringify(mergedConfig, null, 2)}\n`);
  console.log("init.js: existing scrum_crm/config.json preserved (new default keys merged)");
}

const targetClaudeDir = path.join(targetDir, ".claude");
const targetSettingsPath = path.join(targetClaudeDir, "settings.json");
const hostSettingsExist = fs.existsSync(targetSettingsPath);

// A project's own .claude/settings.json is never overwritten: our
// permissions/hook entries are merged into it instead (union of arrays,
// hook appended once). Everything else in claude/ copies over normally
// (cpSync merges directories; the host's extra agents/files survive).
function uniqueUnion(base, extra) {
  return [...new Set([...(base || []), ...(extra || [])])];
}

function mergeSettings(hostSettings, crmSettings) {
  const merged = { ...crmSettings, ...hostSettings };
  merged.permissions = { ...(hostSettings.permissions || {}) };
  merged.permissions.allow = uniqueUnion(hostSettings.permissions?.allow, crmSettings.permissions?.allow);
  merged.permissions.deny = uniqueUnion(hostSettings.permissions?.deny, crmSettings.permissions?.deny);

  merged.hooks = { ...(hostSettings.hooks || {}) };
  const crmPreToolUse = crmSettings.hooks?.PreToolUse || [];
  const hostPreToolUse = hostSettings.hooks?.PreToolUse || [];
  const hostHookCommands = new Set(
    hostPreToolUse.flatMap((entry) => (entry.hooks || []).map((hook) => hook.command)),
  );
  const missingHookEntries = crmPreToolUse.filter(
    (entry) => !(entry.hooks || []).every((hook) => hostHookCommands.has(hook.command)),
  );
  merged.hooks.PreToolUse = [...hostPreToolUse, ...missingHookEntries];
  return merged;
}

console.log(`init.js: copying claude/ to ${targetClaudeDir}`);
fs.cpSync(path.join(packageRoot, "claude"), targetClaudeDir, {
  recursive: true,
  filter: (src) => !(hostSettingsExist && path.basename(src) === "settings.json"),
});

if (hostSettingsExist) {
  const hostSettings = JSON.parse(fs.readFileSync(targetSettingsPath, "utf8"));
  const crmSettings = JSON.parse(fs.readFileSync(path.join(packageRoot, "claude", "settings.json"), "utf8"));
  fs.writeFileSync(targetSettingsPath, `${JSON.stringify(mergeSettings(hostSettings, crmSettings), null, 2)}\n`);
  console.log("init.js: existing .claude/settings.json preserved — CRM permissions/hook merged into it");
}

// Files/dirs from pre-v0.2.0 layouts (shell shims, per-language ports, the
// old root-level db.mjs/board.mjs, the removed guard_db.sh hook) that
// upgrading over an existing install would otherwise leave behind
// alongside the current crm.mjs/lib/* — stale copies shadow the real
// mechanics and get run by muscle-memory (`./db.sh` still "worked").
const OBSOLETE_SCRUM_CRM_ENTRIES = [
  "conventions.md",
  "db.sh",
  "claim.sh",
  "event.sh",
  "fast_open.sh",
  "fast_close.sh",
  "batch_open.sh",
  "batch_close.sh",
  "board.sh",
  "snapshot.sh",
  "restore.sh",
  "lease_sweep.sh",
  "run_tests.sh",
  "config.sh",
  "db.mjs",
  "db.py",
  "batch_open.mjs",
  "batch_open.py",
  "board.mjs",
  "board.py",
  "__pycache__",
];

function removeObsoleteEntry(absolutePath, relativeLabel) {
  if (!fs.existsSync(absolutePath)) {
    return;
  }
  fs.rmSync(absolutePath, { recursive: true, force: true });
  console.log(`init.js: removed obsolete ${relativeLabel}`);
}

for (const entry of OBSOLETE_SCRUM_CRM_ENTRIES) {
  removeObsoleteEntry(path.join(targetDir, "scrum_crm", entry), path.join("scrum_crm", entry));
}
removeObsoleteEntry(
  path.join(targetClaudeDir, "hooks", "guard_db.sh"),
  path.join(".claude", "hooks", "guard_db.sh")
);

const GITIGNORE_ENTRIES = ["scrum_crm/", ".claude/"];
const GITIGNORE_COMMENT = "# agent-scrum runtime state (installed copies)";

function gitignoreHasEntry(content, entry) {
  const bare = entry.endsWith("/") ? entry.slice(0, -1) : entry;
  return content.split("\n").some((line) => {
    const trimmedLine = line.trim();
    return trimmedLine === entry || trimmedLine === bare;
  });
}

// Runs on both fresh installs and upgrades — an existing .gitignore from
// before v0.2.0 (or from the host project) may be missing either entry (or
// both), so an upgrade must backfill whatever's absent, not just a fresh
// install.
function ensureGitignoreHasEntries(projectDir, entries) {
  const gitignorePath = path.join(projectDir, ".gitignore");
  if (!fs.existsSync(gitignorePath)) {
    fs.writeFileSync(gitignorePath, `${entries.join("\n")}\n`);
    for (const entry of entries) {
      console.log(`init.js: added ${entry} to .gitignore`);
    }
    return;
  }
  const gitignoreContent = fs.readFileSync(gitignorePath, "utf8");
  const missingEntries = entries.filter((entry) => !gitignoreHasEntry(gitignoreContent, entry));
  if (missingEntries.length === 0) {
    return;
  }
  const missingTrailingNewline = !gitignoreContent.endsWith("\n");
  fs.appendFileSync(
    gitignorePath,
    `${missingTrailingNewline ? "\n" : ""}${GITIGNORE_COMMENT}\n${missingEntries.join("\n")}\n`
  );
  for (const entry of missingEntries) {
    console.log(`init.js: added ${entry} to .gitignore`);
  }
}

ensureGitignoreHasEntries(targetDir, GITIGNORE_ENTRIES);

// Claude Code's own `@relative/path` import syntax (inside a CLAUDE.md file)
// pulls in another file's content — used here to link CLAUDE.scrum.md into
// an existing host CLAUDE.md so it's actually loaded, instead of sitting on
// disk unused.
const CLAUDE_SCRUM_FILENAME = "CLAUDE.scrum.md";
const CLAUDE_SCRUM_IMPORT_MARKER = `@${CLAUDE_SCRUM_FILENAME}`;
// Earlier versions kept the contract at the project root and imported it
// from .claude/ with a "../" hop; the contract now sits next to its host.
const LEGACY_IMPORT_MARKER = `@../${CLAUDE_SCRUM_FILENAME}`;

function linkClaudeScrumImport(hostPath) {
  const content = fs.readFileSync(hostPath, "utf8");
  if (content.includes(LEGACY_IMPORT_MARKER)) {
    fs.writeFileSync(hostPath, content.split(LEGACY_IMPORT_MARKER).join(CLAUDE_SCRUM_IMPORT_MARKER));
    console.log(`init.js: import updated — ${CLAUDE_SCRUM_FILENAME} now sits next to ${path.basename(hostPath)}`);
    return;
  }
  if (content.includes(CLAUDE_SCRUM_IMPORT_MARKER)) {
    return;
  }
  const missingTrailingNewline = content.length > 0 && !content.endsWith("\n");
  fs.appendFileSync(
    hostPath,
    `${missingTrailingNewline ? "\n" : ""}\n# agent-scrum (imported contract)\n${CLAUDE_SCRUM_IMPORT_MARKER}\n`
  );
  console.log(`init.js: linked ${CLAUDE_SCRUM_FILENAME} via @import in ${path.relative(targetDir, hostPath)}`);
}

// A project keeps its instructions either in <root>/CLAUDE.md or in
// .claude/CLAUDE.md — Claude Code loads both locations. Whichever one the
// project already uses is the host: it is never overwritten, the contract
// goes to CLAUDE.scrum.md and is imported from there.
const rootClaudeMd = path.join(targetDir, "CLAUDE.md");
const dotClaudeMd = path.join(targetClaudeDir, "CLAUDE.md");
const hostClaudeMd = fs.existsSync(rootClaudeMd)
  ? rootClaudeMd
  : fs.existsSync(dotClaudeMd)
    ? dotClaudeMd
    : null;

if (hostClaudeMd && !(forceOverwrite && hostClaudeMd === rootClaudeMd)) {
  // The contract lands in the same directory as the file importing it.
  const contractPath = path.join(path.dirname(hostClaudeMd), CLAUDE_SCRUM_FILENAME);
  console.error(
    `init.js: ${path.relative(targetDir, hostClaudeMd)} already exists, writing ${path.relative(targetDir, contractPath)} instead of overwriting (use --force to overwrite)`
  );
  fs.copyFileSync(path.join(packageRoot, "CLAUDE.md"), contractPath);
  linkClaudeScrumImport(hostClaudeMd);
  const strandedRootContract = path.join(targetDir, CLAUDE_SCRUM_FILENAME);
  if (contractPath !== strandedRootContract && fs.existsSync(strandedRootContract)) {
    fs.rmSync(strandedRootContract);
    console.log(`init.js: removed the obsolete root ${CLAUDE_SCRUM_FILENAME} (it now lives beside the host file)`);
  }
} else if (hostClaudeMd) {
  console.error(
    `init.js: --force given, overwriting ${rootClaudeMd} — pre-existing host rules there are replaced`
  );
  fs.copyFileSync(path.join(packageRoot, "CLAUDE.md"), rootClaudeMd);
} else {
  fs.copyFileSync(path.join(packageRoot, "CLAUDE.md"), rootClaudeMd);
}

console.log("init.js: initializing DB in the target project");
const result = spawnSync(
  process.execPath,
  [path.join(targetDir, "scrum_crm", "crm.mjs"), "init"],
  { cwd: targetDir, stdio: "inherit" }
);

if (result.error) {
  console.error(`init.js: failed to initialize the DB: ${result.error.message}`);
  process.exit(1);
}

if (result.status !== 0) {
  process.exit(result.status === null ? 1 : result.status);
}

// Upgrade migration: an existing crm.db carries its status machine inside
// the tasks CHECK constraint and the triggers, and `crm.mjs init` is all
// CREATE IF NOT EXISTS — it never alters them. When the shipped init.sql
// knows statuses/triggers the DB predates (REVIEWING, enforce_blocked_reason),
// rebuild the tasks table in place, preserving every row. Idempotent.
const migrateScript = `
const { DatabaseSync } = require("node:sqlite");
const fs = require("fs");
const [dbPath, initSqlPath] = process.argv.slice(1);
const db = new DatabaseSync(dbPath);
const initSql = fs.readFileSync(initSqlPath, "utf8");
db.exec("PRAGMA foreign_keys=OFF");
db.exec("PRAGMA legacy_alter_table=ON");
const tableRow = db.prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name='tasks'").get();
const needsRebuild =
  tableRow &&
  (!tableRow.sql.includes("'REVIEWING'") || !tableRow.sql.includes("holder_pid") || !tableRow.sql.includes("'BACKLOG'") || !tableRow.sql.includes("summary"));
if (needsRebuild) {
  // The CHECK constraint or column set predates the current schema:
  // rebuild the table in place, every row preserved (columns copied by
  // name — new columns default to NULL).
  db.exec("DROP TRIGGER IF EXISTS enforce_status_flow");
  db.exec("DROP TRIGGER IF EXISTS enforce_blocked_reason");
  db.exec("DROP TRIGGER IF EXISTS log_status_transition");
  db.exec("ALTER TABLE tasks RENAME TO tasks_migrating");
  db.exec(initSql);
  const oldCols = db.prepare("SELECT name FROM pragma_table_info('tasks_migrating')").all().map((r) => r.name);
  const newCols = new Set(db.prepare("SELECT name FROM pragma_table_info('tasks')").all().map((r) => r.name));
  const shared = oldCols.filter((c) => newCols.has(c)).join(", ");
  db.exec("INSERT INTO tasks (" + shared + ") SELECT " + shared + " FROM tasks_migrating");
  db.exec("DROP TABLE tasks_migrating");
  console.log("init.js: crm.db schema migrated to the current status machine");
} else {
  // Triggers hold no data — recreate them unconditionally so an upgraded
  // init.sql's transition rules always take effect on an existing DB.
  db.exec("DROP TRIGGER IF EXISTS enforce_status_flow");
  db.exec("DROP TRIGGER IF EXISTS enforce_blocked_reason");
  db.exec("DROP TRIGGER IF EXISTS log_status_transition");
  db.exec(initSql);
  console.log("init.js: crm.db triggers refreshed to the current transition rules");
}
`;
const migrateResult = spawnSync(
  process.execPath,
  ["--no-warnings", "-e", migrateScript, "--",
    path.join(targetDir, "scrum_crm", "crm.db"),
    path.join(targetDir, "scrum_crm", "init.sql")],
  { cwd: targetDir, stdio: "inherit" }
);
if (migrateResult.status !== 0) {
  console.error("init.js: crm.db schema migration failed — the DB is untouched or renamed to tasks_migrating; inspect scrum_crm/crm.db before re-running");
  process.exit(migrateResult.status === null ? 1 : migrateResult.status);
}

// Setup questionnaire: pipeline stages are optional and configurable.
// Interactive terminal only; --yes (or no TTY) keeps the defaults.
// Asked in order; a question with askIf is only put to the user when its
// predicate holds — conventions are what the reviewer checks against, so
// the question follows the review answer and is skipped without it.
const STAGE_QUESTIONS = [
  { key: "intakeEnabled", defaultValue: false, prompt: "Enable Stage 0 requirements intake (clarifying questions about the spec before any work)? [y/N] " },
  { key: "reviewEnabled", defaultValue: false, prompt: "Enable the code-review stage (a reviewer agent checks each task before tests)? [y/N] " },
  {
    key: "conventionsEnabled",
    defaultValue: false,
    askIf: (answers) => answers.reviewEnabled,
    prompt: "  └ check code against the project's conventions file (auto-detected; fallback scrum_crm/code_conventions.md)? [y/N] ",
  },
  { key: "testsEnabled", defaultValue: true, prompt: "Enable per-task tests and the Definition of Done check (a task cannot close on red/missing tests)? [Y/n] " },
  { key: "docsEnabled", defaultValue: false, prompt: "Enable a SEPARATE docs stage (a doc-writer agent producing docs/tasks/<id>.md)? Docstrings are written with the code either way. [y/N] " },
];

function parseYesNo(answer, defaultValue) {
  const normalized = answer.trim().toLowerCase();
  if (normalized === "") return defaultValue;
  return normalized === "y" || normalized === "yes" || normalized === "да" || normalized === "д";
}

const TEST_RUNNERS = ["jest", "vitest", "pytest", "plainNode"];
const RUNNER_ALIASES = { node: "plainNode", "plain node": "plainNode" };

function writeStageConfig(answers, runnerName) {
  const configPath = path.join(targetDir, "scrum_crm", "config.json");
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  for (const [key, value] of Object.entries(answers)) {
    config[key] = value;
  }
  // conventionsEnabled is a questionnaire-only key: it selects the
  // conventionsFile mode ('auto' resolution vs disabled) and is not
  // stored itself.
  config.conventionsFile = answers.conventionsEnabled ? "auto" : "";
  delete config.conventionsEnabled;
  if (runnerName !== null) {
    const runnerPair = (config.testCmdExamples || {})[runnerName];
    if (runnerPair && runnerPair.testCmdTask && runnerPair.testCmdAll) {
      config.testCmdTask = runnerPair.testCmdTask;
      config.testCmdAll = runnerPair.testCmdAll;
    }
  }
  fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
  const runnerLabel = runnerName === null ? "skipped (edit scrum_crm/config.json)" : runnerName;
  console.log(
    `init.js: configured — intake ${answers.intakeEnabled ? "on" : "off"}, review ${answers.reviewEnabled ? "on" : "off"}, conventions ${answers.conventionsEnabled ? "on" : "off"}, tests ${answers.testsEnabled ? "on" : "off"}, docs ${answers.docsEnabled ? "on" : "off"}, plan ${answers.planMode || "auto"}, runner ${runnerLabel}`
  );
}

// auto = the context-fit gate decides; ask = confirm before PLAN;
// off = never PLAN (batch-open refuses, so it cannot start by accident).
function parsePlanMode(answer) {
  const normalized = answer.trim().toLowerCase();
  if (normalized === "2" || normalized === "ask") return "ask";
  if (normalized === "3" || normalized === "off") return "off";
  return "auto";
}

// Returns a runner name, or null = the user declined the choice (config
// left untouched, to be edited manually in scrum_crm/config.json).
function parseRunner(answer) {
  const normalized = answer.trim().toLowerCase();
  if (normalized === "") return "jest";
  if (normalized === "0" || normalized === "s" || normalized === "skip") return null;
  const byIndex = TEST_RUNNERS[Number(normalized) - 1];
  if (byIndex) return byIndex;
  if (TEST_RUNNERS.includes(normalized)) return normalized;
  if (RUNNER_ALIASES[normalized]) return RUNNER_ALIASES[normalized];
  console.log(`init.js: unknown runner '${answer.trim()}', keeping jest`);
  return "jest";
}

async function runQuestionnaire() {
  const answers = {};
  if (hostConfigExists) {
    console.log("init.js: upgrade detected — questionnaire skipped, existing config kept (edit scrum_crm/config.json to change stages/runner)");
    return;
  }
  if (skipQuestionnaire || !process.stdin.isTTY || !process.stdout.isTTY) {
    for (const question of STAGE_QUESTIONS) {
      answers[question.key] = question.defaultValue;
    }
    writeStageConfig(answers, "jest");
    return;
  }

  const readline = require("node:readline/promises");
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  let runnerName = "jest";
  try {
    for (const question of STAGE_QUESTIONS) {
      if (question.askIf && !question.askIf(answers)) {
        answers[question.key] = question.defaultValue;
        continue;
      }
      const reply = await rl.question(`init.js: ${question.prompt}`);
      answers[question.key] = parseYesNo(reply, question.defaultValue);
    }
    if (answers.testsEnabled) {
      const reply = await rl.question("init.js: Test runner? 1=jest (default), 2=vitest, 3=pytest, 4=plain node, 0=skip (configure later): ");
      runnerName = parseRunner(reply);
    }
    const planReply = await rl.question(
      "init.js: When the work does not fit the context window — 1=PLAN automatically (default), 2=ask me first, 3=never PLAN: "
    );
    answers.planMode = parsePlanMode(planReply);
  } catch {
    console.log("init.js: questionnaire interrupted — keeping defaults for the unanswered questions");
  } finally {
    rl.close();
  }
  for (const question of STAGE_QUESTIONS) {
    if (!(question.key in answers)) {
      answers[question.key] = question.defaultValue;
    }
  }
  writeStageConfig(answers, runnerName);
}

runQuestionnaire().then(() => {
  console.log("init.js: done. Next step:");
  console.log(`  cd ${targetDir} && claude "your request"`);
});
