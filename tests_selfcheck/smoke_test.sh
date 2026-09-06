#!/usr/bin/env bash
# End-to-end smoke test of Scrum-CRM (spec §8).
# Deploys the system via install.sh onto a clean polygon in scratchpad,
# deterministically simulates dev/qa/doc/scrum-master WITHOUT an LLM — via
# direct calls to `node scrum_crm/crm.mjs db/claim/snapshot/sweep/run-tests`,
# exactly as prescribed by .claude/agents/*.md. Verifies acceptance criteria P1-P9.
# The polygon is removed on completion. exit 0 only if all P1-P9 PASS.
set -uo pipefail

SOURCE_CRM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_DIR="${AGENT_SCRUM_TEST_TMP:-$(mktemp -d /tmp/agent-scrum-smoke.XXXXXX)}/crm_smoke"
LEASE_STALE_MINUTES=30
LEASE_STALE_OFFSET="-2 hours"

DB=()
CLAIM=()
SNAPSHOT=()
RESTORE=()
LEASE_SWEEP=()
RUN_TESTS=()
DB_STDERR_LOG=""

declare -A CRIT_STATUS
declare -A CRIT_REASON
for c in P1 P2 P3 P4 P5 P6 P7 P8 P9; do
  CRIT_STATUS[$c]="FAIL"
  CRIT_REASON[$c]="check not reached (scenario aborted earlier)"
done

mark() {
  local id="$1" status="$2" reason="$3"
  CRIT_STATUS[$id]="$status"
  CRIT_REASON[$id]="$reason"
}

step() {
  echo "==> $1"
}

cleanup_scratch() {
  rm -rf "$SCRATCH_DIR"
}

print_summary() {
  echo "----"
  local crit
  for crit in P1 P2 P3 P4 P5 P6 P7 P8 P9; do
    printf '%-4s %-4s %s\n' "$crit" "${CRIT_STATUS[$crit]}" "${CRIT_REASON[$crit]}"
  done
  echo "P10  SKIP already covered by tests_selfcheck/mechanics_test.sh (scenarios 8-9: guard_db.js blocks direct sqlite3 / allows crm.mjs db)"
}

fatal() {
  echo "FATAL: $1" >&2
  print_summary
  exit 1
}

db() {
  "${DB[@]}" --unsafe-write "$@" 2>>"$DB_STDERR_LOG"
}

dbs() {
  "${DB[@]}" --scalar --unsafe-write "$@" 2>>"$DB_STDERR_LOG"
}

any_fail() {
  local crit
  for crit in P1 P2 P3 P4 P5 P6 P7 P8 P9; do
    [[ "${CRIT_STATUS[$crit]}" != "PASS" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# STEP 0: deploy the system onto a clean polygon via install.sh
# ---------------------------------------------------------------------------
prepare_polygon() {
  step "STEP 0: install.sh -> $SCRATCH_DIR"
  rm -rf "$SCRATCH_DIR"
  mkdir -p "$(dirname "$SCRATCH_DIR")"

  "$SOURCE_CRM_DIR/install.sh" "$SCRATCH_DIR" >/dev/null \
    || fatal "install.sh crashed while deploying the polygon"

  local crm_mjs="$SCRATCH_DIR/scrum_crm/crm.mjs"
  DB=(node "$crm_mjs" db)
  CLAIM=(node "$crm_mjs" claim)
  SNAPSHOT=(node "$crm_mjs" snapshot)
  RESTORE=(node "$crm_mjs" restore)
  LEASE_SWEEP=(node "$crm_mjs" sweep)
  RUN_TESTS=(node "$crm_mjs" run-tests)
  DB_STDERR_LOG="$SCRATCH_DIR/.smoke_db_stderr.log"
  : > "$DB_STDERR_LOG"

  [[ -f "$SCRATCH_DIR/scrum_crm/crm.db" ]] \
    || fatal "install.sh did not initialize crm.db (the crm.mjs init step did not run)"

  # jest is not installed on the polygon -> a plain-node runner replaces the
  # regular config.json test commands. run-tests runs the command via a
  # shell, so the loop below is compatible with that mechanism.
  cat > "$SCRATCH_DIR/scrum_crm/config.json" <<'EOF'
{
  "testCmdTask": "node \"tests/task_{ID}.test.js\"",
  "testCmdAll": "for f in tests/task_*.test.js; do node \"$f\" || exit 1; done"
}
EOF

  mkdir -p "$SCRATCH_DIR/src" "$SCRATCH_DIR/tests" "$SCRATCH_DIR/docs/tasks"
}

# ---------------------------------------------------------------------------
# STEP 1: Product Owner — 4 Stories captured in the BACKLOG
# ---------------------------------------------------------------------------
S1_ID=""; S2_ID=""; S3_ID=""; S4_ID=""

insert_story() {
  local title="$1" description="$2" priority="$3"
  dbs "INSERT INTO tasks (title, description, priority) VALUES (?,?,?) RETURNING id" \
    "$title" "$description" "$priority"
}

product_owner_wave() {
  step "STEP 1: Product Owner — creates S1-S4 (BACKLOG)"

  S1_ID="$(insert_story 'S1: slugify basic' \
'Spec: implement slugify(input) in src/slug.js.

Acceptance Criteria:
Given the string "Hello World"
When slugify("Hello World") is called
Then the result is "hello-world"

Given the string "  A  B  " with extra spaces at the edges and inside
When slugify("  A  B  ") is called
Then the result is "a-b"

Given the empty string ""
When slugify("") is called
Then the result is ""' 5)"

  S2_ID="$(insert_story 'S2: slugify maxLength' \
'Spec: extend slugify(input, maxLength) in src/slug.js with an optional
length limit on a word boundary, without breaking S1 behavior when the
second argument is omitted.

Acceptance Criteria:
Given the string "one two three" and maxLength=7
When slugify("one two three", 7) is called
Then the result is "one-two"

Given a call without maxLength
When slugify("Hello World") is called
Then the result is "hello-world" (S1 behavior unchanged)' 3)"

  S3_ID="$(insert_story 'S3: renderTitle' \
'Spec: implement renderTitle(title) in src/render.js, using slugify from S1.

Acceptance Criteria:
Given the title "My Post"
When renderTitle("My Post") is called
Then the result is `<h1 id="my-post">My Post</h1>`' 4)"

  S4_ID="$(insert_story 'S4: padNum' \
'Spec: implement padNum(num, width) in src/format.js.

Acceptance Criteria:
Given num=7, width=3
When padNum(7, 3) is called
Then the result is "007"

Given num=1234, width=3 (the number is already longer than width)
When padNum(1234, 3) is called
Then the result is "1234"' 4)"

  [[ -n "$S1_ID" && -n "$S2_ID" && -n "$S3_ID" && -n "$S4_ID" ]] \
    || fatal "Product Owner: failed to get ids for all 4 tasks (S1=$S1_ID S2=$S2_ID S3=$S3_ID S4=$S4_ID)"

  echo "    S1=$S1_ID S2=$S2_ID S3=$S3_ID S4=$S4_ID"
}

# ---------------------------------------------------------------------------
# STEP 2: Team Lead — task_files, task_deps (S3->S1, with a cycle check), READY
# ---------------------------------------------------------------------------
team_lead_wave() {
  step "STEP 2: Team Lead — assigning files, dependencies, moving to READY"

  db "INSERT INTO task_files (task_id, path) VALUES (?,?)" "$S1_ID" "src/slug.js" >/dev/null
  db "INSERT INTO task_files (task_id, path) VALUES (?,?)" "$S1_ID" "tests/task_${S1_ID}.test.js" >/dev/null
  db "INSERT INTO task_files (task_id, path) VALUES (?,?)" "$S1_ID" "docs/tasks/${S1_ID}.md" >/dev/null

  db "INSERT INTO task_files (task_id, path) VALUES (?,?)" "$S2_ID" "src/slug.js" >/dev/null
  db "INSERT INTO task_files (task_id, path) VALUES (?,?)" "$S2_ID" "tests/task_${S2_ID}.test.js" >/dev/null
  db "INSERT INTO task_files (task_id, path) VALUES (?,?)" "$S2_ID" "docs/tasks/${S2_ID}.md" >/dev/null

  db "INSERT INTO task_files (task_id, path) VALUES (?,?)" "$S3_ID" "src/render.js" >/dev/null
  db "INSERT INTO task_files (task_id, path) VALUES (?,?)" "$S3_ID" "tests/task_${S3_ID}.test.js" >/dev/null
  db "INSERT INTO task_files (task_id, path) VALUES (?,?)" "$S3_ID" "docs/tasks/${S3_ID}.md" >/dev/null

  db "INSERT INTO task_files (task_id, path) VALUES (?,?)" "$S4_ID" "src/format.js" >/dev/null
  db "INSERT INTO task_files (task_id, path) VALUES (?,?)" "$S4_ID" "tests/task_${S4_ID}.test.js" >/dev/null
  db "INSERT INTO task_files (task_id, path) VALUES (?,?)" "$S4_ID" "docs/tasks/${S4_ID}.md" >/dev/null

  # S3 depends_on S1 — first check for a cycle with a recursive CTE (team-lead.md).
  local cycle_check
  cycle_check="$(dbs "WITH RECURSIVE reach(id) AS (SELECT CAST(? AS INTEGER) UNION SELECT d.depends_on_id FROM task_deps d JOIN reach r ON d.task_id = r.id) SELECT 1 FROM reach WHERE id = CAST(? AS INTEGER)" "$S1_ID" "$S3_ID")"
  [[ -z "$cycle_check" ]] || fatal "team-lead: CTE unexpectedly detected a cycle when inserting S3->S1"

  db "INSERT INTO task_deps (task_id, depends_on_id) VALUES (?,?)" "$S3_ID" "$S1_ID" >/dev/null

  # BACKLOG -> PLANNING (the stories are being refined) -> READY_FOR_DEV:
  # the trigger allows no shortcut between the two.
  db "UPDATE tasks SET status='PLANNING' WHERE id IN (?,?,?,?) AND status='BACKLOG'" \
    "$S1_ID" "$S2_ID" "$S3_ID" "$S4_ID" >/dev/null
  db "UPDATE tasks SET status='READY_FOR_DEV' WHERE id IN (?,?,?,?) AND status='PLANNING'" \
    "$S1_ID" "$S2_ID" "$S3_ID" "$S4_ID" >/dev/null

  local ready_count
  ready_count="$(dbs "SELECT COUNT(*) FROM tasks WHERE id IN (?,?,?,?) AND status='READY_FOR_DEV'" "$S1_ID" "$S2_ID" "$S3_ID" "$S4_ID")"
  [[ "$ready_count" == "4" ]] || fatal "team-lead: expected 4 tasks in READY_FOR_DEV, got $ready_count"
}

# ---------------------------------------------------------------------------
# Helpers: working with crm.mjs claim
# ---------------------------------------------------------------------------
CLAIM_ID=""
CLAIM_AGENT=""

# P3 (part 1, dev_wave_1) fills these variables; qa_wave_1 (part 2)
# reads them and sets the final CRIT_STATUS[P3].
P3_PART1_OK=""
P3_PART1_DETAIL=""

do_claim() {
  local role="$1"
  local out
  out="$("${CLAIM[@]}" "$role")"
  CLAIM_ID=""
  CLAIM_AGENT=""
  if [[ -n "$out" ]]; then
    read -r CLAIM_ID CLAIM_AGENT <<< "$out"
  fi
}

# ---------------------------------------------------------------------------
# Polygon product code implementations (written by "developer")
# ---------------------------------------------------------------------------
write_slug_basic() {
  cat > "$SCRATCH_DIR/src/slug.js" <<'EOF'
function slugify(input) {
  return input.trim().toLowerCase().replace(/\s+/g, '-');
}

module.exports = { slugify };
EOF
}

write_slug_with_max_length() {
  cat > "$SCRATCH_DIR/src/slug.js" <<'EOF'
/**
 * Converts a string to slug form: trims edges, collapses internal
 * whitespace into a single dash, lowercases the result. The optional
 * maxLength truncates the result on a word boundary, never splitting a
 * word in the middle.
 * @param {string} input source string
 * @param {number} [maxLength] maximum result length (on a word boundary)
 * @returns {string} slug
 */
function slugify(input, maxLength) {
  const words = input.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const fullSlug = words.join('-');

  if (maxLength === undefined || fullSlug.length <= maxLength) {
    return fullSlug;
  }

  let truncatedSlug = '';
  for (const word of words) {
    const candidateSlug = truncatedSlug ? `${truncatedSlug}-${word}` : word;
    if (candidateSlug.length > maxLength) {
      break;
    }
    truncatedSlug = candidateSlug;
  }
  return truncatedSlug;
}

module.exports = { slugify };
EOF
}

write_slug_broken_syntax() {
  # P4: fault injection — a syntax error in S1's product file.
  cat > "$SCRATCH_DIR/src/slug.js" <<'EOF'
function slugify(input maxLength) {
  return input.trim().toLowerCase().replace(/\s+/g, '-');
}

module.exports = { slugify };
EOF
}

write_slug_crash_garbage() {
  # P5: simulates an unfinished edit from a crashed agent.
  cat > "$SCRATCH_DIR/src/slug.js" <<'EOF'
function slugify(input) {
  return input.trim(
EOF
}

write_format() {
  cat > "$SCRATCH_DIR/src/format.js" <<'EOF'
function padNum(num, width) {
  return String(num).padStart(width, '0');
}

module.exports = { padNum };
EOF
}

write_render() {
  cat > "$SCRATCH_DIR/src/render.js" <<'EOF'
const { slugify } = require('./slug');

function renderTitle(title) {
  return `<h1 id="${slugify(title)}">${title}</h1>`;
}

module.exports = { renderTitle };
EOF
}

# JSDoc versions for the doc-writer step (comments only, logic unchanged).
write_format_documented() {
  cat > "$SCRATCH_DIR/src/format.js" <<'EOF'
/**
 * Pads a number on the left with zeros to a given width.
 * @param {number} num source number
 * @param {number} width desired minimum length of the result
 * @returns {string} number left-padded with zeros
 */
function padNum(num, width) {
  return String(num).padStart(width, '0');
}

module.exports = { padNum };
EOF
}

write_render_documented() {
  cat > "$SCRATCH_DIR/src/render.js" <<'EOF'
const { slugify } = require('./slug');

/**
 * Renders a title as an <h1> with an id attribute derived via slugify.
 * @param {string} title title text
 * @returns {string} title HTML markup
 */
function renderTitle(title) {
  return `<h1 id="${slugify(title)}">${title}</h1>`;
}

module.exports = { renderTitle };
EOF
}

# ---------------------------------------------------------------------------
# Polygon tests (written by "qa", node:assert)
# ---------------------------------------------------------------------------
write_test_1() {
  cat > "$SCRATCH_DIR/tests/task_${S1_ID}.test.js" <<EOF
const assert = require('node:assert');
const { slugify } = require('../src/slug');

assert.strictEqual(slugify('Hello World'), 'hello-world');
assert.strictEqual(slugify('  A  B  '), 'a-b');
assert.strictEqual(slugify(''), '');

console.log('task_${S1_ID}: OK');
EOF
}

write_test_2() {
  cat > "$SCRATCH_DIR/tests/task_${S2_ID}.test.js" <<EOF
const assert = require('node:assert');
const { slugify } = require('../src/slug');

assert.strictEqual(slugify('one two three', 7), 'one-two');
assert.strictEqual(slugify('Hello World'), 'hello-world');

console.log('task_${S2_ID}: OK');
EOF
}

write_test_3() {
  cat > "$SCRATCH_DIR/tests/task_${S3_ID}.test.js" <<EOF
const assert = require('node:assert');
const { renderTitle } = require('../src/render');

assert.strictEqual(renderTitle('My Post'), '<h1 id="my-post">My Post</h1>');

console.log('task_${S3_ID}: OK');
EOF
}

write_test_4() {
  cat > "$SCRATCH_DIR/tests/task_${S4_ID}.test.js" <<EOF
const assert = require('node:assert');
const { padNum } = require('../src/format');

assert.strictEqual(padNum(7, 3), '007');
assert.strictEqual(padNum(1234, 3), '1234');

console.log('task_${S4_ID}: OK');
EOF
}

# ---------------------------------------------------------------------------
# Task documentation (written by "doc-writer")
# ---------------------------------------------------------------------------
write_doc() {
  local task_id="$1" title="$2" body="$3"
  cat > "$SCRATCH_DIR/docs/tasks/${task_id}.md" <<EOF
# ${title}

${body}
EOF
}

# ---------------------------------------------------------------------------
# STEP 3: Dev wave #1 — dev claims S1 and S4, P2/P3 are checked
# ---------------------------------------------------------------------------
dev_wave_1() {
  step "STEP 3: Dev wave 1 — claim S1, S4; checking P2 (file) and P3 (dependency)"

  do_claim dev
  [[ "$CLAIM_ID" == "$S1_ID" ]] || fatal "dev claim 1: expected S1 ($S1_ID), got '$CLAIM_ID'"
  "${SNAPSHOT[@]}" "$S1_ID"
  write_slug_basic
  db "UPDATE tasks SET status='READY_FOR_TEST', assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S1_ID" "$CLAIM_AGENT" >/dev/null

  # P2: while S1 (shared file src/slug.js) is active, S2 must not be issued.
  # Checking the EXACT same subquery construct used by crm.mjs claim.
  local conflict_for_s2
  conflict_for_s2="$(dbs "SELECT o.id FROM task_files f1 JOIN task_files f2 ON f2.path = f1.path AND f2.task_id <> f1.task_id JOIN tasks o ON o.id = f2.task_id WHERE f1.task_id = ? AND o.status IN ('CODING','READY_FOR_REVIEW','REVIEWING','READY_FOR_TEST','TESTING','READY_FOR_DOCS','DOCUMENTING')" "$S2_ID")"
  if [[ "$conflict_for_s2" == "$S1_ID" ]]; then
    mark P2 PASS "S2 (id=$S2_ID) is blocked by the shared file src/slug.js, held by S1 (id=$S1_ID, status READY_FOR_TEST)"
  else
    mark P2 FAIL "expected a conflict with S1 (id=$S1_ID), crm.mjs claim subquery returned '$conflict_for_s2'"
  fi

  # P3 (part 1): S3 depends on S1, S1 is now READY_FOR_TEST -> the dependency
  # is not yet satisfied (crm.mjs claim gate: parent.status IN ('READY_FOR_DOCS','DOCUMENTING',
  # 'DONE','CANCELLED') satisfies the dependency; READY_FOR_TEST is not in that
  # list) -> S3 must not be issued. Exact copy of crm.mjs claim's subquery.
  local dep_block_for_s3
  dep_block_for_s3="$(dbs "SELECT 1 FROM task_deps d JOIN tasks p ON p.id = d.depends_on_id WHERE d.task_id = ? AND p.status NOT IN ('READY_FOR_DOCS','DOCUMENTING','DONE','CANCELLED')" "$S3_ID")"
  if [[ "$dep_block_for_s3" == "1" ]]; then
    P3_PART1_OK="true"
    P3_PART1_DETAIL="S3 (id=$S3_ID) is blocked by the unfinished dependency S1 (id=$S1_ID, status READY_FOR_TEST, not in READY_FOR_DOCS/DOCUMENTING/DONE/CANCELLED)"
  else
    P3_PART1_OK="false"
    P3_PART1_DETAIL="expected the dependency block at status READY_FOR_TEST, crm.mjs claim subquery returned '$dep_block_for_s3'"
  fi

  # S4 doesn't overlap by files and has no dependencies -> claim must issue it in parallel.
  do_claim dev
  [[ "$CLAIM_ID" == "$S4_ID" ]] || fatal "dev claim 2: expected S4 ($S4_ID) in parallel with active S1, got '$CLAIM_ID'"
  "${SNAPSHOT[@]}" "$S4_ID"
  write_format
  db "UPDATE tasks SET status='READY_FOR_TEST', assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S4_ID" "$CLAIM_AGENT" >/dev/null

  # The queue must now be empty: S2 (file) and S3 (dependency) are blocked.
  do_claim dev
  [[ -z "$CLAIM_ID" ]] || fatal "dev claim 3: expected an empty queue (S2/S3 blocked), got '$CLAIM_ID'"
}

# ---------------------------------------------------------------------------
# STEP 4: QA wave 1
# ---------------------------------------------------------------------------
qa_wave_1() {
  step "STEP 4: QA wave 1 — S1, S4"

  do_claim qa
  [[ "$CLAIM_ID" == "$S1_ID" ]] || fatal "qa claim 1: expected S1 ($S1_ID), got '$CLAIM_ID'"
  write_test_1
  local log rc
  log="$("${RUN_TESTS[@]}" "$S1_ID")"; rc=$?
  [[ "$rc" -eq 0 ]] || fatal "crm.mjs run-tests $S1_ID crashed unexpectedly (rc=$rc), log: $log"
  db "UPDATE tasks SET status='READY_FOR_DOCS', error_log_path=NULL, assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S1_ID" "$CLAIM_AGENT" >/dev/null

  # P3 (part 2): S1 is now READY_FOR_DOCS -> S3's dependency is satisfied, crm.mjs claim
  # must issue S3. S1 (src/slug.js) and S3 (src/render.js) don't overlap by
  # files, so this is a clean check of the dependency gate specifically, not
  # the file lock. The claim here is a probe: S3 is immediately returned to
  # READY_FOR_DEV; the real claim of S3 happens later, in wave 2 (STEP 9),
  # once S1 is already DONE.
  do_claim dev
  if [[ "$CLAIM_ID" == "$S3_ID" ]]; then
    db "UPDATE tasks SET status='READY_FOR_DEV', assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
      "$S3_ID" "$CLAIM_AGENT" >/dev/null
    if [[ "$P3_PART1_OK" == "true" ]]; then
      mark P3 PASS "$P3_PART1_DETAIL; once S1 moved to READY_FOR_DOCS the dependency was satisfied — crm.mjs claim issued S3 (id=$S3_ID)"
    else
      mark P3 FAIL "$P3_PART1_DETAIL"
    fi
  else
    mark P3 FAIL "expected that with S1 (id=$S1_ID) in status READY_FOR_DOCS crm.mjs claim would issue S3 (id=$S3_ID), got '$CLAIM_ID'"
  fi

  do_claim qa
  [[ "$CLAIM_ID" == "$S4_ID" ]] || fatal "qa claim 2: expected S4 ($S4_ID), got '$CLAIM_ID'"
  write_test_4
  log="$("${RUN_TESTS[@]}" "$S4_ID")"; rc=$?
  [[ "$rc" -eq 0 ]] || fatal "crm.mjs run-tests $S4_ID crashed unexpectedly (rc=$rc), log: $log"
  db "UPDATE tasks SET status='READY_FOR_DOCS', error_log_path=NULL, assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S4_ID" "$CLAIM_AGENT" >/dev/null

  do_claim qa
  [[ -z "$CLAIM_ID" ]] || fatal "qa claim 3: expected an empty queue, got '$CLAIM_ID'"
}

# ---------------------------------------------------------------------------
# STEP 5: Doc wave 1
# ---------------------------------------------------------------------------
doc_wave_1() {
  step "STEP 5: Doc wave 1 — S1, S4"

  do_claim doc
  [[ "$CLAIM_ID" == "$S1_ID" ]] || fatal "doc claim 1: expected S1 ($S1_ID), got '$CLAIM_ID'"
  write_doc "$S1_ID" "S1: slugify basic" "Implementation of \`slugify(input)\` in \`src/slug.js\`. Converts a string to a slug: trims edges, collapses whitespace into a dash, lowercases."
  db "UPDATE tasks SET status='DOCUMENTING', assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S1_ID" "$CLAIM_AGENT" >/dev/null

  do_claim doc
  [[ "$CLAIM_ID" == "$S4_ID" ]] || fatal "doc claim 2: expected S4 ($S4_ID), got '$CLAIM_ID'"
  write_format_documented
  write_doc "$S4_ID" "S4: padNum" "Implementation of \`padNum(num, width)\` in \`src/format.js\`. Pads a number with zeros on the left to a given width."
  db "UPDATE tasks SET status='DOCUMENTING', assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S4_ID" "$CLAIM_AGENT" >/dev/null

  do_claim doc
  [[ -z "$CLAIM_ID" ]] || fatal "doc claim 3: expected an empty queue, got '$CLAIM_ID'"
}

# ---------------------------------------------------------------------------
# STEP 6: Fault injection (P4) — break the first DOCUMENTING task's product file
# ---------------------------------------------------------------------------
FAULT_LOG=""

fault_injection() {
  step "STEP 6: fault injection (P4) — syntax error in src/slug.js (task S1)"

  local first_documented
  first_documented="$(dbs "SELECT id FROM tasks WHERE status='DOCUMENTING' ORDER BY id ASC LIMIT 1")"
  [[ "$first_documented" == "$S1_ID" ]] || fatal "expected the first DOCUMENTING task to be S1 ($S1_ID), got '$first_documented'"

  write_slug_broken_syntax

  local log rc
  log="$("${RUN_TESTS[@]}" all)"; rc=$?
  FAULT_LOG="$log"
  if [[ "$rc" -eq 0 ]]; then
    mark P4 FAIL "crm.mjs run-tests all after breaking src/slug.js was expected to be red, got rc=0"
    return
  fi

  [[ -f "$log" ]] || fatal "crm.mjs run-tests all did not create a log at path '$log'"

  local culprit
  culprit="$(grep -oE 'task_[0-9]+' "$log" | head -n1 | sed -E 's/task_([0-9]+)/\1/')"
  [[ "$culprit" == "$S1_ID" ]] || fatal "culprit attribution: expected task_${S1_ID}, log points to task_${culprit:-?}"

  # The new schema has no separate NEED_REFACTOR: a red Definition of Done at DOCUMENTING
  # sends the task straight back to READY_FOR_DEV, the return context lives
  # in error_log_path/resolution_hint + loop_count (see the
  # enforce_status_flow trigger).
  local resolution_hint_text="red Definition of Done: syntax error in src/slug.js (task_${S1_ID}), see error_log_path"
  db "UPDATE tasks SET status='READY_FOR_DEV', error_log_path=?, resolution_hint=?, loop_count=loop_count+1 WHERE id=? AND status='DOCUMENTING'" \
    "$log" "$resolution_hint_text" "$S1_ID" >/dev/null

  local status_after loop_after error_after hint_after
  status_after="$(dbs "SELECT status FROM tasks WHERE id=?" "$S1_ID")"
  loop_after="$(dbs "SELECT loop_count FROM tasks WHERE id=?" "$S1_ID")"
  error_after="$(dbs "SELECT COALESCE(error_log_path,'') FROM tasks WHERE id=?" "$S1_ID")"
  hint_after="$(dbs "SELECT COALESCE(resolution_hint,'') FROM tasks WHERE id=?" "$S1_ID")"

  if [[ "$status_after" == "READY_FOR_DEV" && "$loop_after" -ge 1 && -n "$error_after" && -f "$error_after" && -n "$hint_after" ]]; then
    mark P4 PASS "S1 -> READY_FOR_DEV (red Definition of Done), loop_count=$loop_after, error_log_path=$error_after (exists), resolution_hint filled, culprit correctly attributed (task_${S1_ID})"
  else
    mark P4 FAIL "after escalation: status='$status_after' loop_count='$loop_after' error_log_path='$error_after' resolution_hint='$hint_after'"
  fi
}

# ---------------------------------------------------------------------------
# STEP 7: S1 repair cycle (dev -> qa -> doc), then mini-Definition of Done (S1, S4 -> DONE)
# ---------------------------------------------------------------------------
repair_and_first_dod() {
  step "STEP 7: repairing S1 (READY_FOR_DEV after a red Definition of Done -> ... -> DOCUMENTING), first Definition of Done pass"

  do_claim dev
  [[ "$CLAIM_ID" == "$S1_ID" ]] || fatal "dev claim (repair): expected S1 ($S1_ID) from READY_FOR_DEV (red Definition of Done), got '$CLAIM_ID'"
  "${SNAPSHOT[@]}" "$S1_ID"
  # developer reads error_log_path/resolution_hint, fixes exactly the
  # recorded failure — returns the correct basic implementation of S1
  # (a maxLength-compatible signature isn't needed yet, S2 isn't implemented yet).
  write_slug_basic
  db "UPDATE tasks SET status='READY_FOR_TEST', assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S1_ID" "$CLAIM_AGENT" >/dev/null

  do_claim dev
  [[ -z "$CLAIM_ID" ]] || fatal "dev claim after repairing S1: expected an empty queue, got '$CLAIM_ID'"

  do_claim qa
  [[ "$CLAIM_ID" == "$S1_ID" ]] || fatal "qa claim (repair): expected S1 ($S1_ID), got '$CLAIM_ID'"
  local log rc
  log="$("${RUN_TESTS[@]}" "$S1_ID")"; rc=$?
  [[ "$rc" -eq 0 ]] || fatal "crm.mjs run-tests $S1_ID crashed unexpectedly after the repair (rc=$rc), log: $log"
  db "UPDATE tasks SET status='READY_FOR_DOCS', error_log_path=NULL, resolution_hint=NULL, assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S1_ID" "$CLAIM_AGENT" >/dev/null

  do_claim doc
  [[ "$CLAIM_ID" == "$S1_ID" ]] || fatal "doc claim (repair): expected S1 ($S1_ID), got '$CLAIM_ID'"
  write_doc "$S1_ID" "S1: slugify basic" "Implementation of \`slugify(input)\` in \`src/slug.js\`. Converts a string to a slug: trims edges, collapses whitespace into a dash, lowercases."
  db "UPDATE tasks SET status='DOCUMENTING', assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S1_ID" "$CLAIM_AGENT" >/dev/null

  # scrum-master: Definition of Done pass #1 (S1, S4 are now DOCUMENTING, S2/S3 not ready yet).
  log="$("${RUN_TESTS[@]}" all)"; rc=$?
  [[ "$rc" -eq 0 ]] || fatal "crm.mjs run-tests all (Definition of Done #1) was expected to be green, rc=$rc, log: $log"

  db "UPDATE tasks SET status='DONE' WHERE status='DOCUMENTING'" >/dev/null

  local done_count
  done_count="$(dbs "SELECT COUNT(*) FROM tasks WHERE id IN (?,?) AND status='DONE'" "$S1_ID" "$S4_ID")"
  [[ "$done_count" == "2" ]] || fatal "Definition of Done #1: expected S1 and S4 in DONE, got $done_count"

  rebuild_readme
  rm -rf "$SCRATCH_DIR/scrum_crm/snapshots/${S1_ID}" "$SCRATCH_DIR/scrum_crm/snapshots/${S4_ID}"
}

rebuild_readme() {
  local out="$SCRATCH_DIR/README.md"
  {
    echo "# Scrum-CRM smoke polygon — aggregated documentation"
    echo
    local f
    for f in "$SCRATCH_DIR"/docs/tasks/*.md; do
      [[ -f "$f" ]] || continue
      cat "$f"
      echo
      echo "---"
      echo
    done
  } > "$out"
}

# ---------------------------------------------------------------------------
# STEP 8: simulate an agent crash (P5) on S2 — artificial claim + crash
# ---------------------------------------------------------------------------
crash_simulation() {
  step "STEP 8: simulating an agent crash (P5) on S2"

  # Artificial claim (bypassing crm.mjs claim — simulating that an agent WAS
  # ALREADY working on the task and crashed), since per the crm.mjs claim
  # contract S2 would not actually be blocked at this point (S1 is already
  # DONE), but we specifically need a CODING status with a stale locked_at
  # to test crm.mjs sweep.
  db "UPDATE tasks SET status='CODING', assigned_agent='dev_crashed_sim', locked_at=datetime('now') WHERE id=? AND status='READY_FOR_DEV'" \
    "$S2_ID" >/dev/null

  local claimed_status
  claimed_status="$(dbs "SELECT status FROM tasks WHERE id=?" "$S2_ID")"
  [[ "$claimed_status" == "CODING" ]] || fatal "crash-sim: failed to artificially move S2 to CODING (status '$claimed_status')"

  "${SNAPSHOT[@]}" "$S2_ID"
  local pre_crash_slug
  pre_crash_slug="$(cat "$SCRATCH_DIR/src/slug.js")"

  write_slug_crash_garbage

  db "UPDATE tasks SET locked_at = datetime('now', ?) WHERE id=?" "$LEASE_STALE_OFFSET" "$S2_ID" >/dev/null

  "${LEASE_SWEEP[@]}" "$LEASE_STALE_MINUTES" >/dev/null

  local status_after agent_after slug_after
  status_after="$(dbs "SELECT status FROM tasks WHERE id=?" "$S2_ID")"
  agent_after="$(dbs "SELECT COALESCE(assigned_agent,'') FROM tasks WHERE id=?" "$S2_ID")"
  slug_after="$(cat "$SCRATCH_DIR/src/slug.js")"

  if [[ "$status_after" == "READY_FOR_DEV" && -z "$agent_after" && "$slug_after" == "$pre_crash_slug" ]]; then
    mark P5 PASS "crm.mjs sweep: S2 (id=$S2_ID) CODING -> READY_FOR_DEV, agent=NULL, src/slug.js restored from the snapshot byte-for-byte"
  else
    mark P5 FAIL "status='$status_after' agent='$agent_after' file matches snapshot=$([[ "$slug_after" == "$pre_crash_slug" ]] && echo yes || echo no)"
  fi
}

# ---------------------------------------------------------------------------
# STEP 9: Dev wave #2 — S3 (dependency released) and S2 (file free)
# ---------------------------------------------------------------------------
dev_wave_2() {
  step "STEP 9: Dev wave 2 — S3, S2 (S1 is now DONE: dependency and file are free)"

  do_claim dev
  [[ "$CLAIM_ID" == "$S3_ID" ]] || fatal "dev claim (wave2, 1): expected S3 ($S3_ID, priority 4), got '$CLAIM_ID'"
  "${SNAPSHOT[@]}" "$S3_ID"
  write_render
  db "UPDATE tasks SET status='READY_FOR_TEST', assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S3_ID" "$CLAIM_AGENT" >/dev/null

  do_claim dev
  [[ "$CLAIM_ID" == "$S2_ID" ]] || fatal "dev claim (wave2, 2): expected S2 ($S2_ID, priority 3), got '$CLAIM_ID'"
  "${SNAPSHOT[@]}" "$S2_ID"
  write_slug_with_max_length
  db "UPDATE tasks SET status='READY_FOR_TEST', assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S2_ID" "$CLAIM_AGENT" >/dev/null

  do_claim dev
  [[ -z "$CLAIM_ID" ]] || fatal "dev claim (wave2, 3): expected an empty queue, got '$CLAIM_ID'"
}

qa_wave_2() {
  step "STEP 9b: QA wave 2 — S3, S2"

  do_claim qa
  [[ "$CLAIM_ID" == "$S3_ID" ]] || fatal "qa claim (wave2, 1): expected S3 ($S3_ID), got '$CLAIM_ID'"
  write_test_3
  local log rc
  log="$("${RUN_TESTS[@]}" "$S3_ID")"; rc=$?
  [[ "$rc" -eq 0 ]] || fatal "crm.mjs run-tests $S3_ID crashed unexpectedly (rc=$rc), log: $log"
  db "UPDATE tasks SET status='READY_FOR_DOCS', error_log_path=NULL, assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S3_ID" "$CLAIM_AGENT" >/dev/null

  do_claim qa
  [[ "$CLAIM_ID" == "$S2_ID" ]] || fatal "qa claim (wave2, 2): expected S2 ($S2_ID), got '$CLAIM_ID'"
  write_test_2
  log="$("${RUN_TESTS[@]}" "$S2_ID")"; rc=$?
  [[ "$rc" -eq 0 ]] || fatal "crm.mjs run-tests $S2_ID crashed unexpectedly (rc=$rc), log: $log"
  db "UPDATE tasks SET status='READY_FOR_DOCS', error_log_path=NULL, assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S2_ID" "$CLAIM_AGENT" >/dev/null

  do_claim qa
  [[ -z "$CLAIM_ID" ]] || fatal "qa claim (wave2, 3): expected an empty queue, got '$CLAIM_ID'"
}

doc_wave_2() {
  step "STEP 9c: Doc wave 2 — S3, S2"

  do_claim doc
  [[ "$CLAIM_ID" == "$S3_ID" ]] || fatal "doc claim (wave2, 1): expected S3 ($S3_ID), got '$CLAIM_ID'"
  write_render_documented
  write_doc "$S3_ID" "S3: renderTitle" "Implementation of \`renderTitle(title)\` in \`src/render.js\`. Uses \`slugify\` from S1 to build the title's id."
  db "UPDATE tasks SET status='DOCUMENTING', assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S3_ID" "$CLAIM_AGENT" >/dev/null

  do_claim doc
  [[ "$CLAIM_ID" == "$S2_ID" ]] || fatal "doc claim (wave2, 2): expected S2 ($S2_ID), got '$CLAIM_ID'"
  write_doc "$S2_ID" "S2: slugify maxLength" "Extends \`slugify(input, maxLength)\` in \`src/slug.js\` with an optional length limit on a word boundary."
  db "UPDATE tasks SET status='DOCUMENTING', assigned_agent=NULL, locked_at=NULL WHERE id=? AND assigned_agent=?" \
    "$S2_ID" "$CLAIM_AGENT" >/dev/null

  do_claim doc
  [[ -z "$CLAIM_ID" ]] || fatal "doc claim (wave2, 3): expected an empty queue, got '$CLAIM_ID'"
}

# ---------------------------------------------------------------------------
# STEP 10: Scrum Master — final Definition of Done, criteria P1, P6, P7, P8, P9
# ---------------------------------------------------------------------------
scrum_master_final() {
  step "STEP 10: Scrum Master finale — Definition of Done, README, snapshots, final checks"

  "${LEASE_SWEEP[@]}" "$LEASE_STALE_MINUTES" >/dev/null

  local log rc
  log="$("${RUN_TESTS[@]}" all)"; rc=$?

  local test_file_count
  test_file_count="$(find "$SCRATCH_DIR/tests" -maxdepth 1 -name 'task_*.test.js' -type f | wc -l | tr -d ' ')"

  if [[ "$rc" -eq 0 && "$test_file_count" == "4" ]]; then
    mark P6 PASS "crm.mjs run-tests all rc=0, found 4 test files (tests/task_*.test.js)"
  else
    mark P6 FAIL "rc=$rc test_file_count=$test_file_count (log: $log)"
    fatal "crm.mjs run-tests all (final) is not green, further Definition of Done steps are pointless"
  fi

  db "UPDATE tasks SET status='DONE' WHERE status='DOCUMENTING'" >/dev/null
  rebuild_readme

  local done_count total_count
  done_count="$(dbs "SELECT COUNT(*) FROM tasks WHERE status='DONE'")"
  total_count="$(dbs "SELECT COUNT(*) FROM tasks")"
  if [[ "$done_count" == "4" && "$total_count" == "4" ]]; then
    mark P1 PASS "all 4 tasks are in status DONE"
  else
    mark P1 FAIL "DONE=$done_count out of total=$total_count"
  fi

  # P7: docs/tasks/1..4.md exist, README.md contains their content.
  local docs_ok=true
  local id
  for id in "$S1_ID" "$S2_ID" "$S3_ID" "$S4_ID"; do
    local doc_path="$SCRATCH_DIR/docs/tasks/${id}.md"
    if [[ ! -f "$doc_path" ]]; then
      docs_ok=false
      mark P7 FAIL "docs/tasks/${id}.md is missing"
      break
    fi
    if ! grep -qF "$(cat "$doc_path")" "$SCRATCH_DIR/README.md"; then
      docs_ok=false
      mark P7 FAIL "README.md does not contain the content of docs/tasks/${id}.md"
      break
    fi
  done
  [[ "$docs_ok" == "true" ]] && mark P7 PASS "docs/tasks/{${S1_ID},${S2_ID},${S3_ID},${S4_ID}}.md exist, README.md rebuilt from their content"

  # Remove snapshots of DONE tasks (S2, S3 are moved now; S1/S4 were removed in STEP7).
  rm -rf "$SCRATCH_DIR/scrum_crm/snapshots/${S2_ID}" "$SCRATCH_DIR/scrum_crm/snapshots/${S3_ID}"

  # P8: snapshots/ is empty.
  local snapshots_dir="$SCRATCH_DIR/scrum_crm/snapshots"
  local leftover_count=0
  if [[ -d "$snapshots_dir" ]]; then
    leftover_count="$(find "$snapshots_dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  fi
  if [[ "$leftover_count" == "0" ]]; then
    mark P8 PASS "snapshots/ is empty (all 4 tasks DONE, snapshots removed)"
  else
    mark P8 FAIL "snapshots/ contains $leftover_count item(s) after all tasks completed"
  fi

  # P9: no "Invalid status transition" error during the whole regular run.
  if grep -q 'Invalid status transition' "$DB_STDERR_LOG" 2>/dev/null; then
    mark P9 FAIL "found the message 'Invalid status transition' in $DB_STDERR_LOG during the regular run"
  else
    mark P9 PASS "no crm.mjs db call during the whole run produced 'Invalid status transition' (stderr collected in $DB_STDERR_LOG)"
  fi
}

main() {
  trap cleanup_scratch EXIT

  prepare_polygon
  product_owner_wave
  team_lead_wave
  dev_wave_1
  qa_wave_1
  doc_wave_1
  fault_injection
  repair_and_first_dod
  crash_simulation
  dev_wave_2
  qa_wave_2
  doc_wave_2
  scrum_master_final

  print_summary

  if any_fail; then
    exit 1
  fi
  exit 0
}

main
