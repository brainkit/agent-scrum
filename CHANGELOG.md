# Changelog — Agent Scrum

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.13] - 2026-09-07

- The autocommit question is now a plain yes/no (`1=yes (default),
  2=no`). The third "always" mode still exists — it is a value in
  `config.json`, not a choice worth putting to someone during setup.
- `agent-scrum` with no path installs into the current directory instead
  of printing usage and exiting; the path argument is now optional and
  named `[path_to_project]`. The chosen directory is printed before
  anything is written.

## [0.1.12] - 2026-09-07

- The installer asks about git autocommit as well: commit each finished
  task when the project is a git repo (default, unchanged behaviour),
  never, or always. It writes to your history, so it is a question
  rather than something to discover in `config.json`.

## [0.1.11] - 2026-09-07

- The contract now says plainly what goes through the CRM: every
  request that changes the repository — ops fixes, config edits and
  one-line patches included — is registered before the first edit,
  and the CRM is not opt-in per request. Observed in the field: a
  session with the contract loaded did real work without opening a
  task, because registration only read as a rule for 'proper' coding
  tasks.
- New optional backstop `requireTaskForEdits` (off by default): with
  it on, `claude/hooks/guard_edits.js` refuses `Write`/`Edit` unless the
  session HOLDS A CLAIM on a task, matched through the process ancestry
  of that claim. The guard reads the claim itself, never a list of
  statuses, so it keeps working when the status machine changes — and it
  covers every writing role (QA in TESTING, the doc-writer in
  DOCUMENTING) without naming them. Mechanics scenario 31.

## [0.1.10] - 2026-09-07

- "DoD" is spelled out as "Definition of Done" everywhere a person
  reads it: refusal messages, the events written to the trace, the
  ledger labels, the contract, the role prompts and the docs. The
  ledger still counts events written under the old wording.
- README carries npm/license/node badges linking to the package, so
  the GitHub page points at the published release (GitHub's own
  Packages sidebar only lists GitHub Packages, never npmjs).

## [0.1.9] - 2026-09-06

- Documentation is written with the code, not in a later stage: the
  contract and the developer prompt require docstrings/JSDoc on public
  functions in the same edit as the implementation, and `docsEnabled`
  now governs only a SEPARATE docs stage — off by default, because it
  used to be on while the default route produced no doc file at all.
- With the docs stage ON, a task must say what it did before it can
  close: `set-summary ID "..."` stores a short outcome (<=300 chars)
  with the task itself, `fast-close`/`batch-close` refuse without it
  (the refusal lands in the ledger), and the summary shows on the board
  card, in the task panel and in `board --task`. Mechanics scenario 30.

## [0.1.8] - 2026-09-06

- Narrowed the guards so they stop blocking honest work:
  - the PreToolUse hook now fires only when a command actually runs
    `sqlite3` (or rm/mv/redirect) against a CRM database inside THIS
    project. Mentioning the words in a script, a commit message or a
    changelog is no longer an offence, an unrelated database of your
    own is none of its business, and a throwaway copy under /tmp can
    be deleted.
  - the blanket `Bash(sqlite3:*)` deny rule is gone (the hook covers
    the real case precisely), and the file deny rules are anchored
    with `./` so they protect the installed copy without freezing a
    nested checkout of the tool itself.
  Both behaviours are pinned by mechanics scenario 29.

## [0.1.7] - 2026-09-06

- `crm.mjs report [DAYS] [--json]` — the mechanics ledger: how many
  closes on red tests the Definition of Done check blocked, how many illegal
  transitions the trigger refused, how many tasks were rejected without
  Given/When/Then, how many dead-holder claims were swept, plus rework,
  throughput and audit-trail counts. Every refusal the mechanics make
  is now recorded in `events` (kind='refusal'/'sweep') by the mechanics
  themselves, so the value of the guarantees is measured from your own
  project instead of argued about. Mechanics scenario 28.

## [0.1.6] - 2026-09-06

- New `BACKLOG` status completes the queue/active pattern for planning:
  `BACKLOG` is captured work nobody is on, `PLANNING` means a live
  session is refining it. `claim plan` moves `BACKLOG -> PLANNING` and
  records the holder, so the board shows who is on a task during
  planning and a dead session's task falls back to `BACKLOG` on the
  next sweep. `add-task` now defaults to `BACKLOG`; the trigger allows
  no shortcut from `BACKLOG` to `READY_FOR_DEV`. Existing databases
  are migrated by the installer, tasks already in `PLANNING` stay
  valid. Mechanics scenario 27.

## [0.1.5] - 2026-09-06

- PLAN is now yours to control: `planMode` in `scrum_crm/config.json`
  is `auto` (the context-fit gate decides, unchanged default), `ask`
  (the session prints the gate line and waits for a go-ahead;
  degrades to `auto` where nobody can answer) or `off` (never PLAN).
  `off` is enforced mechanically — `batch-open` refuses, so PLAN
  cannot start by accident (mechanics scenario 26). An explicit
  instruction in the request outranks the gate and the setting.
- Questionnaire: the conventions question now follows the code-review
  question and is asked only when review is enabled (conventions are
  what the reviewer checks against); the plan-mode choice was added.

## [0.1.4] - 2026-09-06

- `CLAUDE.scrum.md` is now written next to the file that imports it, so
  the import is always a plain `@CLAUDE.scrum.md` — a project whose
  rules live in `.claude/CLAUDE.md` gets `.claude/CLAUDE.scrum.md`
  instead of a root file reached with `@../`. Existing installs are
  migrated on upgrade: the import loses the `../` hop and the stray
  root copy is removed.

## [0.1.3] - 2026-09-06

- Dropped the blanket `Edit(.claude/**)` / `Write(.claude/**)` deny
  rules from the shipped settings: they blocked ordinary work in every
  project that keeps its own agents, hooks or notes under `.claude/`.
  The CRM's own protections stay (read-only `db`, the `sqlite3`/crm.db
  guard hook, the deny rules on `scrum_crm/`).

## [0.1.2] - 2026-09-06

- Installer: `.claude/CLAUDE.md` is now recognised as the project's
  instruction file, same as a root `CLAUDE.md`. Projects keeping their
  rules there used to get the contract written into a *second* file at
  the project root, with no import line in the file they actually
  maintain. The contract now goes to `CLAUDE.scrum.md` and is imported
  from whichever host file exists (`@CLAUDE.scrum.md` from the root,
  `@../CLAUDE.scrum.md` from `.claude/`), never overwriting it.
  Covered by mechanics scenario 25.

## [0.1.1] - 2026-09-06

- `agent-scrum` with no arguments now says plainly that a target
  directory is required and nothing was installed, and prints
  copy-pasteable examples (`agent-scrum .` with the resolved current
  directory, `agent-scrum ~/myproject`). `--help`/`-h` print the same
  help and exit 0.

## [0.1.0] - 2026-09-05

Initial release.

- Transactional status machine in SQLite: `PLANNING → READY_FOR_DEV →
  CODING → [READY_FOR_REVIEW → REVIEWING] → [READY_FOR_TEST → TESTING] →
  [READY_FOR_DOCS → DOCUMENTING] → DONE`, validated by a DB trigger;
  optional stage pairs driven by `reviewEnabled`/`testsEnabled`/
  `docsEnabled` in `config.json`. `BLOCKED` is reachable only from
  `CODING` and always carries a reason (`advance ID BLOCKED --hint`,
  backed by the `enforce_blocked_reason` trigger); the only way back is
  `PLANNING` — the task is reformulated so its wording addresses the
  blocker before re-entering the dev queue.
- Atomic claims with file locks and dependency gates; a built-in
  dependency-cycle check in `add-dep`; lease sweep returns stale
  in-progress tasks to their queues; snapshot/restore rollback without
  git.
- Single Node CLI (`scrum_crm/crm.mjs`, Node >= 22.5, `node:sqlite`,
  Windows-native): `init`, read-only `db` (writes only through guarded
  subcommands: `claim`, `fast-open`/`fast-close`, `batch-open`/
  `batch-close`, `advance`, `return`, `release`, `add-task`,
  `add-files`, `add-dep`, `append-desc`, `set-hint`, `set-priority`,
  `event`; raw SQL needs `db --unsafe-write`), `board` (web kanban /
  `--task` card / `--json` dump), `snapshot`/`restore`, `sweep`,
  `run-tests`, `context-fit`.
- Self-contained tasks: `batch-open` accepts `description_from`
  ({file, lines}) pointers and mechanically extracts the full ticket
  text from the backlog file into the task's `description` — the DB is
  the single source of truth, developers read tickets with one SELECT,
  and the orchestrator never retypes a backlog.
- Atomic group operations for parallel groups: `batch-claim` (claim a
  whole pre-assigned group in one transaction, all-or-nothing) and
  `batch-advance` (advance several ids in one trigger-checked
  transaction); developers hand each ticket over per-ticket as it
  finishes, so queues fill early and a crash rolls back only unfinished
  work.
- Hard gates: schema gate (no task without Given/When/Then and files),
  Definition of Done check (no close on a red or missing test suite), context-fit
  routing gate (PLAN only when the work does not fit the context
  window), Node version gate at startup.
- Event trace (`events` table) and optional git autocommit per DONE,
  scoped to the project directory pathspec (safe in shared/nested
  repos).
- Orchestrator contract (`CLAUDE.md`) with SOLO/PARALLEL/PLAN routing,
  Stage 0 requirements intake, context packets; seven role prompts for
  the opt-in full process.
- Installer (`bin/init.js`, npx-ready): setup questionnaire (intake/
  review/tests/docs/conventions toggles — conventions off by default,
  `scrum_crm/code_conventions.md` as the auto-resolution fallback —
  and a test-runner choice with a skip option), preserves
  an existing host `CLAUDE.md` (linked via `@import`) and merges an
  existing `.claude/settings.json` instead of overwriting, maintains
  `.gitignore`, cleans obsolete files on upgrade.
- Holder liveness: every claim records the claiming session's pid and
  process start time; the sweep asks the OS instead of the clock — an
  alive holder is never swept (a human-paced chat can hold a task for
  hours), a dead one is released instantly. `leaseMinutes` remains only
  as the fallback for rows without holder info.
- Self-healing queues: every `claim` sweeps leases older than
  `leaseMinutes` (config, default 30) first, so CODING/REVIEWING/
  TESTING/DOCUMENTING only ever show live work; the board marks stale
  claims.
- Visual task debugging: every status change is logged mechanically by
  the `log_status_transition` trigger (kind='status' in `events`, raw
  writes included); clicking a card on the web board opens the task's
  full journey — status timeline interleaved with agent events, files,
  deps, description (`/task?id=N`).
- Web-only board: `board [port]` — auto-refreshing kanban at 127.0.0.1,
  one strict column per status, zero dependencies (`node:http`);
  `board --json` exposes the same payload for scripts.
- Installer migrates an existing `crm.db` to the current status machine
  on upgrade (table rebuild, all rows preserved).
- Self-check suites: 19 mechanics scenarios and a P1-P9 end-to-end
  smoke run; honest paired benchmarks in the README.

Tested with Claude Code 2.1.261.
