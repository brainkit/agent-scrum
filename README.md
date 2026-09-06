# Agent Scrum

Transactional coordination for Claude Code subagents: a Scrum team whose
rules live in a SQLite database — triggers, atomic claims, file locks,
leases — not in prompts.

## Why

**Process rules live in the database, not in prompts.** Skip a step,
grab another agent's file, close a task without green tests — you get a
SQL error. A prompt is a request an agent can break silently; that
silent drift is the documented failure mode of multi-agent systems
(inter-agent misalignment in the
[MAST taxonomy](https://arxiv.org/abs/2503.13657)).

**Many chats, one project — safe by construction.** Several Claude Code
sessions over the same repo become concurrent actors over shared state:
one DB holds the backlog, each chat `claim`s its next task atomically,
file locks and dependency gates keep them out of each other's work, a
crashed chat's task is released the moment its session dies (OS
liveness check, not a timeout), and the web board shows
everyone's live picture. The state lives in the DB, not in any chat's
context — closing a chat loses nothing.

## Requirements

- Node.js >= 22.5 (bundled `node:sqlite`) — the only runtime dependency.
  Windows/macOS/Linux native. Below 22.5 the CLI refuses with a
  one-line error.
- Claude Code, to drive the roles and hooks.

## Quick start

```bash
# Install into your project (npm package, no clone needed)
npx agent-scrum /path/to/project     # or, from inside the project: npx agent-scrum .

# ...then just work — Claude Code picks up the contract automatically
cd /path/to/project && claude "your request"

# Live dashboard — web kanban at http://127.0.0.1:4553; click a card
# to see the task's full journey (status timeline + agent events)
node scrum_crm/crm.mjs board
```

The installer asks a short questionnaire (intake / review — and, if
review is on, the conventions check / tests / docs stages, test runner,
and how PLAN should be chosen); `--yes` keeps the defaults.
Everything lands in `scrum_crm/config.json`, editable any time.
Your own instructions are never overwritten, wherever Claude Code reads
them from — `CLAUDE.md` at the project root or `.claude/CLAUDE.md`: the
contract goes to a `CLAUDE.scrum.md` written next to that file, and one
`@CLAUDE.scrum.md` import line is appended to it. Re-running the
installer upgrades in place: an existing
`.claude/settings.json` is merged, your config and DB survive (the
schema is migrated when needed).

## Where everything lives

After `npx agent-scrum <project>` the tool owns exactly two directories
and one contract file; everything else in your project is untouched.

| Path | What it is | Who writes it |
|---|---|---|
| `CLAUDE.md` (or `CLAUDE.scrum.md` next to your own instructions) | the orchestrator contract: routing, statuses, the exact CLI calls | the installer; yours is never overwritten |
| `.claude/agents/*.md` | the seven role prompts, loaded by Claude Code on spawn | the installer |
| `.claude/hooks/guard_db.js`, `.claude/settings.json` | the DB guard hook and the pre-allowed/denied commands | the installer (an existing settings file is merged) |
| `scrum_crm/config.json` | your settings: stages, test runner, `planMode`, lease window | the installer questionnaire; yours survives upgrades |
| `scrum_crm/code_conventions.md` | the fallback conventions, used only when the conventions check is on and your project has no file of its own | the installer |
| `scrum_crm/crm.db` | the single source of truth: tasks with full requirements, files, dependencies, and the append-only event trace | the mechanics |
| `scrum_crm/logs/`, `scrum_crm/snapshots/` | test logs kept for returned tasks, and per-task file snapshots for rollback | the mechanics |
| `docs/tasks/<id>.md` + a short summary in the DB | per-task documentation — only when the separate docs stage is on (off by default); the summary is what the board shows | the doc-writer agent |
| docstrings / JSDoc in the task's own files | the default documentation, written together with the code in every route | whoever wrote the code |

To see what a task produced, ask the board rather than hunting for
files: `node scrum_crm/crm.mjs board --task <id>` prints its
requirement, its file list (the doc file included, when there is one),
its dependencies and the full event trace; the web board shows the same
on a click. Nothing above needs reading by hand — the DB is queried
through `crm.mjs db`/`board`/`report`, and the contract is loaded by
Claude Code automatically. `scrum_crm/` and `.claude/` are added to `.gitignore` by
the installer, so the runtime state stays out of your history.

**In this repository** (if you cloned it rather than installed it):
`README.md` is this page, `CLAUDE.md` is the contract that gets
installed, `BENCHMARKS.md` holds the measurements and their method,
`CHANGELOG.md` the version history, and `tests_selfcheck/` the two
self-check suites.

## Concrete guarantees

Every row is a mechanical check, not a policy; "scenario N" is a
numbered test in `tests_selfcheck/mechanics_test.sh` you can run
yourself.

| Guarantee | Enforced by | Verify |
|---|---|---|
| A task can't skip the pipeline | trigger `enforce_status_flow` in `scrum_crm/init.sql` | scenario 5 |
| Two agents can never edit the same file concurrently | file-lock subquery in `claim` | scenario 1 |
| A task with unfinished dependencies can't be claimed | dependency gate in `claim` | scenario 2 |
| A parallel claim race resolves to exactly one winner | atomic `UPDATE ... RETURNING` | scenario 3 |
| A crashed session can't hold work hostage | holder liveness: claims record the session's pid+start time; a dead holder is released instantly, an alive one never (lease timeout only as fallback); `CODING` rolls back via snapshot | scenarios 10, 22 |
| In-progress columns only ever show live work — planning included | every `claim` sweeps dead-holder claims first; `PLANNING` is entered via `claim plan` and falls back to `BACKLOG` | scenarios 18, 27 |
| A task can't be `BLOCKED` without a stated reason | `advance --hint` check + `enforce_blocked_reason` trigger | scenario 19 |
| A task can't enter work without Given/When/Then criteria and files | schema gate in `fast-open`/`batch-open` | scenario 12 |
| A task can't close `DONE` on red or missing tests | DoD gate inside `fast-close`/`batch-close` | try it — they refuse |
| Every task leaves an audit trail (who, what, when, why) | `tasks` history + append-only `events` | scenario 13 |
| Bad edits roll back without touching Git | per-task `snapshot`/`restore` | scenario 7 |
| Every `DONE` can be a Git commit | `gitAutocommit`, pathspec-scoped (nested-repo safe) | scenario 14 |
| A dependency cycle is rejected before it exists | recursive-CTE check in `add-dep` | scenario 4 |
| Group claims/advances are all-or-nothing | one transaction in `batch-claim`/`batch-advance` | scenario 20 |
| Every task in the DB is self-contained (full requirement, not a summary) | `batch-open` `description_from` mechanical extraction | scenario 21 |
| With the docs stage on, nothing closes without saying what it did | `set-summary` (capped, stored with the task) + a close gate in `fast-close`/`batch-close`; shown on the board | scenario 30 |
| PLAN can be switched off for good, not just discouraged | `planMode: "off"` makes `batch-open` refuse — PLAN's only door into a backlog | scenario 26 |
| The full process provably involves every role | each stage is enterable only via its role's `claim` channel; the `events` trace names all seven roles per task | scenario 23 |
| A task's full journey is reconstructible without trusting anyone | `log_status_transition` trigger records every status change into `events` mechanically — raw writes included | scenario 24 |

## Benchmarks

Median of 3 simultaneous pairs per task against a plain no-CRM agent,
held-out acceptance tests: bugfix **160s vs 231s** (Agent Scrum
faster), feature **119s vs 120s** (parity), 20-ticket backlog
**229s vs 210s** (parity within spread), 60-ticket PLAN lean vs
prompt-only delegation **369s vs 305s** (~+20%, the bookkeeping wave).
Quality parity everywhere. Full tables, cost accounting and the
measured laws: [BENCHMARKS.md](BENCHMARKS.md).

## Status machine

```
BACKLOG → PLANNING → READY_FOR_DEV → CODING → [READY_FOR_REVIEW → REVIEWING] →
  [READY_FOR_TEST → TESTING] → [READY_FOR_DOCS → DOCUMENTING] → DONE

CODING → BLOCKED → PLANNING   (blocker requires a stated reason; the way
                               back is reformulation, never the same text)

[...] — optional pairs: reviewEnabled / testsEnabled / docsEnabled
```

Every stage is a queue/active pair, planning included: `BACKLOG` is
captured work nobody is on, `PLANNING` means a live session is refining
it (entered with `claim plan`, holder recorded — so the board shows who,
and a dead session's task returns to `BACKLOG`). Any return for rework
goes to `READY_FOR_DEV` — one entry point.
`CANCELLED` is a human decision on a task not yet in work; terminal.
Transitions are validated by a DB trigger — an invalid one fails with
`Invalid status transition`.

## How it works

Routing is a mechanical gate (`context-fit`: does the read/write set
fit the context window?), never a judgment call — and you stay in
charge of it: `planMode` in `scrum_crm/config.json` is `auto` (the gate
decides), `ask` (the session asks before going PLAN) or `off` (never
PLAN — `batch-open` refuses, so it cannot start by accident), and an
explicit instruction in your request outranks all of it. What each mode
is for:

- **FAST / SOLO** — the task fits one session's head: do it now, no
  roles, full DB audit kept. The default for most requests.
- **FAST / PARALLEL** — the same small task splits into 2-3 independent
  chunks, each big enough to pay for its own executor: buying time
  with parallelism, nothing else.
- **PLAN (lean)** — the work doesn't fit one context: decompose into
  disjoint groups, keep the backlog in the DB, dispatch executors.
  Default PLAN — measurement showed manager roles eating the pipeline.
- **PLAN (full process)** — only when the process itself is the goal
  (independent reviewer/QA, role-by-role audit); gated by context-fit
  AND an explicit request.

The DB has one door: `crm.mjs db` is read-only for agents; every write
goes through guarded subcommands (`claim`, `advance`,
`batch-claim`/`batch-advance`, `fast-open`/`fast-close`,
`batch-open`/`batch-close`, ...); raw write SQL needs an explicit
`--unsafe-write`, meant for humans. Full contract with worked routing
examples: `CLAUDE.md` in this folder.

```bash
node scrum_crm/crm.mjs board --task 42   # task card: fields, files, deps, trace
node scrum_crm/crm.mjs board --json      # board payload for scripts
node scrum_crm/crm.mjs report            # mechanics ledger (see below)
```

## Is it worth it? Measure, don't argue

Speed and cost are the wrong question here — measured, this system is at
parity with a plain agent at best ([BENCHMARKS.md](BENCHMARKS.md)). What
it sells is refusals: the steps that would otherwise pass unnoticed. So
it counts them for you, from its own database:

```bash
node scrum_crm/crm.mjs report 30        # last 30 days, human-readable
node scrum_crm/crm.mjs report 30 --json # same numbers for scripts
```

```
Silent failures prevented (each would have passed unnoticed)
  close on red or missing tests blocked (DoD gate)....     7
  illegal status transitions refused..................     0
  ...
  TOTAL...............................................     7
```

Every line is written by the mechanics themselves at the moment they
refuse (`kind='refusal'`/`'sweep'` in `events`), never by an agent
reporting on its own work. Run it after a few weeks of real use: if the
total stays at zero, nothing on your workload ever tried to skip the
process and the guarantees are costing you their overhead for nothing —
that is a real answer, and the system will give it to you honestly.

## Self-checks

```bash
./tests_selfcheck/mechanics_test.sh   # 30 scenarios, exit 0 = all pass
./tests_selfcheck/smoke_test.sh       # P1-P9 end-to-end, no LLM involved
```

## Threat model: drift, not sabotage

The guarantees protect against **drift** — an agent *forgetting* the
process (skipping a step, taking a held file, declaring victory without
tests), which
[MAST](https://arxiv.org/abs/2503.13657) documents as the dominant
failure class of multi-agent LLM systems and practitioners
([Cognition](https://cognition.com/blog/dont-build-multi-agents),
[Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system))
report from production. They do **not** protect against deliberate
sabotage: an agent with Bash has the user's rights, and only an
OS-level sandbox stops intent. The design direction is to keep moving
rules out of prompts into mechanics, so the drift surface shrinks;
routing and judgment stay in prompts because they must.

## Security

Mechanic calls are pre-allowed in `claude/settings.json`; a PreToolUse
hook blocks commands that actually reach this project's `crm.db` outside
the sanctioned CLI (a direct `sqlite3` call, `rm`/`mv`/a redirect onto
it). The guard is deliberately narrow — mentioning those names in a
script or a commit message is not an attack, your own unrelated
databases are untouched, and the shipped deny rules are anchored to the
installed copy — because a guard that cries wolf is a guard people work
around. No network calls anywhere in `scrum_crm/` or `claude/hooks/` —
every file is short enough to audit:
`wc -l scrum_crm/crm.mjs scrum_crm/lib/*.mjs claude/hooks/*.js`.

## vs. alternatives

- **NEEDLE** — SQLite task queue, headless; not Claude-native.
- **CAS** — git-worktree isolation, not DB transactions; no trigger/gates.
- **claude-flow** — prompt-based coordination; no enforced invariants.
- **Claude Code Agent Teams** — shared file list; no transactions,
  locks, leases or DoD gate.

## Status

Experimental, best-effort support. Tested with Claude Code 2.1.261.
MIT license.
