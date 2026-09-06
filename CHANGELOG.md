# Changelog — Agent Scrum

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
  DoD gate (no close on a red or missing test suite), context-fit
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
