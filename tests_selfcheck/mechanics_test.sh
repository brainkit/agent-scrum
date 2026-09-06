#!/usr/bin/env bash
# Acceptance test of Scrum-CRM mechanics (spec §9, 16 scenarios).
# Runs on a TEMPORARY copy of the system — never touches the live scrum_crm/crm.db.
# exit 0 only if all scenarios PASS.
set -uo pipefail

SOURCE_CRM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Throwaway workspace: honor $AGENT_SCRUM_TEST_TMP if set, else mktemp.
TEST_TMP_ROOT="${AGENT_SCRUM_TEST_TMP:-$(mktemp -d /tmp/agent-scrum-mech.XXXXXX)}"
SCRATCH_DIR="$TEST_TMP_ROOT/crm_mech_test"
GIT_SCRATCH_DIR="$TEST_TMP_ROOT/crm_mech_test_git"
GIT_NESTED_SCRATCH_DIR="$TEST_TMP_ROOT/crm_mech_test_git_nested"
LEASE_STALE_MINUTES=30
LEASE_STALE_OFFSET="-2 hours"

DB=()
CLAIM=()
SNAPSHOT=()
RESTORE=()
LEASE_SWEEP=()
INIT_CMD=()
GUARD_DB_JS=""
FAST_OPEN=()
FAST_CLOSE=()
BATCH_OPEN=()
BATCH_CLOSE=()
EVENT=()
BOARD=()
BOARD_CARD=()

PASS_COUNT=0
FAIL_COUNT=0
FAIL_NAMES=()

report_pass() {
  local scenario_name="$1"
  echo "PASS  $scenario_name"
  PASS_COUNT=$((PASS_COUNT + 1))
}

report_fail() {
  local scenario_name="$1"
  local reason="$2"
  echo "FAIL  $scenario_name"
  echo "      reason: $reason"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAIL_NAMES+=("$scenario_name")
}

cleanup_scratch() {
  rm -rf "$SCRATCH_DIR" "$GIT_SCRATCH_DIR" "$GIT_NESTED_SCRATCH_DIR"
}

prepare_scratch_copy() {
  rm -rf "$SCRATCH_DIR"
  mkdir -p "$(dirname "$SCRATCH_DIR")"
  rsync -a --exclude='tests_selfcheck' --exclude='.git' --exclude='crm.db*' --exclude='node_modules' "$SOURCE_CRM_DIR/" "$SCRATCH_DIR/"

  local crm_mjs="$SCRATCH_DIR/scrum_crm/crm.mjs"
  DB=(node "$crm_mjs" db --unsafe-write)
  CLAIM=(node "$crm_mjs" claim)
  SNAPSHOT=(node "$crm_mjs" snapshot)
  RESTORE=(node "$crm_mjs" restore)
  LEASE_SWEEP=(node "$crm_mjs" sweep)
  INIT_CMD=(node "$crm_mjs" init)
  FAST_OPEN=(node "$crm_mjs" fast-open)
  FAST_CLOSE=(node "$crm_mjs" fast-close)
  BATCH_OPEN=(node "$crm_mjs" batch-open)
  BATCH_CLOSE=(node "$crm_mjs" batch-close)
  EVENT=(node "$crm_mjs" event)
  BOARD=(node "$crm_mjs" board --json)
  BOARD_CARD=(node "$crm_mjs" board)
  # prepare_scratch_copy does a "raw" rsync of the whole tree (without
  # install.sh), so claude/ stays claude/ here instead of .claude/ — the
  # rename to .claude/ is only done by install.sh (checked in smoke_test.sh).
  # settings.json's real PreToolUse hook is claude/hooks/guard_db.js — a
  # freshly installed polygon has it at .claude/hooks/guard_db.js; this raw
  # rsync copy keeps claude/ unrenamed, so the path here mirrors that.
  GUARD_DB_JS="$SCRATCH_DIR/claude/hooks/guard_db.js"

  # jest is not installed on the polygon -> a plain-node runner replaces the
  # regular config.json test commands, same substitution smoke_test.sh does
  # for its own polygon. run-tests runs the command via a shell, so this
  # is transparent to fast-close/batch-close's DoD gate.
  cat > "$SCRATCH_DIR/scrum_crm/config.json" <<'EOF'
{
  "testCmdTask": "node \"tests/task_{ID}.test.js\"",
  "testCmdAll": "for f in tests/task_*.test.js; do node \"$f\" || exit 1; done",
  "gitAutocommit": "auto"
}
EOF

  mkdir -p "$SCRATCH_DIR/tests"
}

# Writes a task's DoD test file as a trivially passing node:assert script.
write_passing_test() {
  local test_id="$1"
  mkdir -p "$SCRATCH_DIR/tests"
  cat > "$SCRATCH_DIR/tests/task_${test_id}.test.js" <<EOF
const assert = require('node:assert');
assert.strictEqual(1 + 1, 2);
EOF
}

# Writes a task's DoD test file as a deliberately failing node:assert script.
write_failing_test() {
  local test_id="$1"
  mkdir -p "$SCRATCH_DIR/tests"
  cat > "$SCRATCH_DIR/tests/task_${test_id}.test.js" <<EOF
const assert = require('node:assert');
assert.strictEqual(1 + 1, 3);
EOF
}

reset_database() {
  rm -f "$SCRATCH_DIR/scrum_crm/crm.db" "$SCRATCH_DIR/scrum_crm/crm.db-wal" "$SCRATCH_DIR/scrum_crm/crm.db-shm"
  rm -rf "$SCRATCH_DIR/scrum_crm/snapshots"
  # task ids restart from 1 on every reset — clear stray DoD test files so an
  # earlier scenario's tests/task_<id>.test.js can't leak into this one.
  rm -rf "$SCRATCH_DIR/tests"
  mkdir -p "$SCRATCH_DIR/tests"
  "${INIT_CMD[@]}" >/dev/null
}

insert_task() {
  local title="$1"
  local status="$2"
  local priority="$3"
  "${DB[@]}" --scalar "INSERT INTO tasks (title, description, status, priority) VALUES (?, 'd', ?, ?) RETURNING id" \
    "$title" "$status" "$priority"
}

move_task_through_chain() {
  # Moves a task through a chain of statuses using SEPARATE UPDATE queries.
  local task_id="$1"
  shift
  local target_status
  for target_status in "$@"; do
    "${DB[@]}" "UPDATE tasks SET status=? WHERE id=?" "$target_status" "$task_id" >/dev/null
  done
}

select_scalar_field() {
  local sql="$1"
  shift
  "${DB[@]}" --scalar "$sql" "$@"
}

# --- Scenario 1: shared file, different priority, serialization until DONE ---
scenario_01_shared_file_serialization() {
  local scenario_name="1: shared file serializes claim until DONE"
  reset_database

  local task_high task_low
  task_high="$(insert_task 'T1 high prio' 'READY_FOR_DEV' 10)"
  task_low="$(insert_task 'T2 low prio' 'READY_FOR_DEV' 5)"
  "${DB[@]}" "INSERT INTO task_files (task_id, path) VALUES (?, 'shared.txt')" "$task_high" >/dev/null
  "${DB[@]}" "INSERT INTO task_files (task_id, path) VALUES (?, 'shared.txt')" "$task_low" >/dev/null

  local claim1
  claim1="$("${CLAIM[@]}" dev)"
  if [[ "$claim1" != "$task_high"* ]]; then
    report_fail "$scenario_name" "first claim expected task_id=$task_high (highest priority), got '$claim1'"
    return
  fi

  local claim2
  claim2="$("${CLAIM[@]}" dev)"
  if [[ -n "$claim2" ]]; then
    report_fail "$scenario_name" "repeat claim before the first task's DONE expected empty, got '$claim2'"
    return
  fi

  move_task_through_chain "$task_high" READY_FOR_TEST TESTING READY_FOR_DOCS DOCUMENTING DONE

  local claim3
  claim3="$("${CLAIM[@]}" dev)"
  if [[ "$claim3" != "$task_low"* ]]; then
    report_fail "$scenario_name" "claim after the first task's DONE expected task_id=$task_low, got '$claim3'"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 2: dependency (task_deps) blocks claim until parent reaches READY_FOR_DOCS ---
scenario_02_dependency_blocks_claim() {
  local scenario_name="2: task_deps blocks claim until parent reaches READY_FOR_DOCS (QA passed)"
  reset_database

  local parent_id child_id
  parent_id="$(insert_task 'Parent' 'PLANNING' 0)"
  child_id="$(insert_task 'Child' 'READY_FOR_DEV' 0)"
  "${DB[@]}" "INSERT INTO task_deps (task_id, depends_on_id) VALUES (?, ?)" "$child_id" "$parent_id" >/dev/null
  # Parent and child files are deliberately different — this checks the
  # dependency gate specifically, not the file lock (that one holds until
  # DONE separately).
  "${DB[@]}" "INSERT INTO task_files (task_id, path) VALUES (?, 'parent.txt')" "$parent_id" >/dev/null
  "${DB[@]}" "INSERT INTO task_files (task_id, path) VALUES (?, 'child.txt')" "$child_id" >/dev/null

  local claim1
  claim1="$("${CLAIM[@]}" dev)"
  if [[ -n "$claim1" ]]; then
    report_fail "$scenario_name" "claim with parent in PLANNING expected empty, got '$claim1'"
    return
  fi

  move_task_through_chain "$parent_id" READY_FOR_DEV CODING READY_FOR_TEST TESTING

  local claim2
  claim2="$("${CLAIM[@]}" dev)"
  if [[ -n "$claim2" ]]; then
    report_fail "$scenario_name" "claim with parent in TESTING expected empty, got '$claim2'"
    return
  fi

  move_task_through_chain "$parent_id" READY_FOR_DOCS

  local claim3
  claim3="$("${CLAIM[@]}" dev)"
  if [[ "$claim3" != "$child_id"* ]]; then
    report_fail "$scenario_name" "claim after moving parent to READY_FOR_DOCS expected task_id=$child_id, got '$claim3'"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 3: two parallel crm.mjs claim dev calls for one READY task ---
scenario_03_parallel_claim_exclusivity() {
  local scenario_name="3: parallel claim captures the task exactly once"
  reset_database

  insert_task 'Solo READY_FOR_DEV' 'READY_FOR_DEV' 0 >/dev/null

  local out_a out_b
  out_a="$(mktemp)"
  out_b="$(mktemp)"

  ( "${CLAIM[@]}" dev > "$out_a" ) &
  local pid_a=$!
  ( "${CLAIM[@]}" dev > "$out_b" ) &
  local pid_b=$!
  wait "$pid_a"
  wait "$pid_b"

  local result_a result_b
  result_a="$(cat "$out_a")"
  result_b="$(cat "$out_b")"
  rm -f "$out_a" "$out_b"

  local non_empty_count=0
  [[ -n "$result_a" ]] && non_empty_count=$((non_empty_count + 1))
  [[ -n "$result_b" ]] && non_empty_count=$((non_empty_count + 1))

  if [[ "$non_empty_count" -ne 1 ]]; then
    report_fail "$scenario_name" "expected exactly one non-empty result, got: a='$result_a' b='$result_b'"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 4: cycle detection in task_deps via recursive CTE ---
scenario_04_cycle_detection_cte() {
  local scenario_name="4: recursive CTE detects the A->B->A cycle"
  reset_database

  local task_a task_b
  task_a="$(insert_task 'A' 'PLANNING' 0)"
  task_b="$(insert_task 'B' 'PLANNING' 0)"
  # A depends_on B: task_id=A, depends_on_id=B
  "${DB[@]}" "INSERT INTO task_deps (task_id, depends_on_id) VALUES (?, ?)" "$task_a" "$task_b" >/dev/null

  # Check before the hypothetical insert of B depends_on A (task_id=B, depends_on_id=A):
  # parent=A (new depends_on_id), child=B (new task_id).
  local cte_result
  cte_result="$("${DB[@]}" --scalar "WITH RECURSIVE reach(id) AS (SELECT ? UNION SELECT d.depends_on_id FROM task_deps d JOIN reach r ON d.task_id=r.id) SELECT 1 FROM reach WHERE id=?" "$task_a" "$task_b")"

  if [[ "$cte_result" != "1" ]]; then
    report_fail "$scenario_name" "CTE expected '1' (cycle detected), got '$cte_result'"
    return
  fi

  # The B->A insert is NOT performed (per the team-lead.md contract); confirm it's absent from the DB.
  local reverse_edge_count
  reverse_edge_count="$(select_scalar_field "SELECT COUNT(*) FROM task_deps WHERE task_id=? AND depends_on_id=?" "$task_b" "$task_a")"
  if [[ "$reverse_edge_count" != "0" ]]; then
    report_fail "$scenario_name" "reverse edge B->A must not exist, found $reverse_edge_count"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 5: an invalid status transition is rolled back by the trigger ---
scenario_05_invalid_status_transition_rejected() {
  local scenario_name="5: READY_FOR_DEV->DONE directly is rejected by the trigger"
  reset_database

  local task_id
  task_id="$(insert_task 'Ready task' 'READY_FOR_DEV' 0)"

  local stderr_file
  stderr_file="$(mktemp)"
  local exit_code=0
  "${DB[@]}" "UPDATE tasks SET status='DONE' WHERE id=?" "$task_id" >/dev/null 2>"$stderr_file" || exit_code=$?
  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  rm -f "$stderr_file"

  if [[ "$exit_code" -ne 1 ]]; then
    report_fail "$scenario_name" "expected exit 1, got $exit_code"
    return
  fi
  if [[ "$stderr_content" != *"Invalid status transition"* ]]; then
    report_fail "$scenario_name" "expected an error message in stderr, got: '$stderr_content'"
    return
  fi

  local actual_status
  actual_status="$(select_scalar_field "SELECT status FROM tasks WHERE id=?" "$task_id")"
  if [[ "$actual_status" != "READY_FOR_DEV" ]]; then
    report_fail "$scenario_name" "status must remain READY_FOR_DEV, became '$actual_status'"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 6: special characters in a parameter round-trip byte-for-byte ---
scenario_06_special_characters_roundtrip() {
  local scenario_name="6: special characters (quotes, \$VAR, an actual newline) byte-for-byte"
  reset_database

  local special_value
  special_value="it's \"quoted\" \$VAR
newline"

  local task_id
  task_id="$("${DB[@]}" --scalar "INSERT INTO tasks (title, description, status) VALUES (?, 'd', 'PLANNING') RETURNING id" "$special_value")"

  local retrieved_value
  retrieved_value="$("${DB[@]}" "SELECT title FROM tasks WHERE id=?" "$task_id" | jq -r '.[0].title')"

  if [[ "$retrieved_value" != "$special_value" ]]; then
    report_fail "$scenario_name" "round-trip mismatch. expected: $(printf '%q' "$special_value"); got: $(printf '%q' "$retrieved_value")"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 7: crm.mjs snapshot / crm.mjs restore revert an edit and remove the new file ---
scenario_07_snapshot_restore_roundtrip() {
  local scenario_name="7: crm.mjs snapshot + crm.mjs restore revert the file and remove the new one"
  reset_database

  local task_id
  task_id="$(insert_task 'Snapshot task' 'PLANNING' 0)"

  local existing_relative_path="scratch_test/existing.txt"
  local new_relative_path="scratch_test/newfile.txt"
  local existing_absolute_path="$SCRATCH_DIR/$existing_relative_path"
  local new_absolute_path="$SCRATCH_DIR/$new_relative_path"

  mkdir -p "$(dirname "$existing_absolute_path")"
  printf 'A' > "$existing_absolute_path"
  rm -f "$new_absolute_path"

  "${DB[@]}" "INSERT INTO task_files (task_id, path) VALUES (?, ?)" "$task_id" "$existing_relative_path" >/dev/null
  "${DB[@]}" "INSERT INTO task_files (task_id, path) VALUES (?, ?)" "$task_id" "$new_relative_path" >/dev/null

  "${SNAPSHOT[@]}" "$task_id"

  printf 'B' > "$existing_absolute_path"
  printf 'created-by-dev' > "$new_absolute_path"

  "${RESTORE[@]}" "$task_id"

  local existing_content_after
  existing_content_after="$(cat "$existing_absolute_path")"
  if [[ "$existing_content_after" != "A" ]]; then
    report_fail "$scenario_name" "existing file must revert to 'A', contains '$existing_content_after'"
    return
  fi
  if [[ -f "$new_absolute_path" ]]; then
    report_fail "$scenario_name" "new file must be removed by crm.mjs restore, but it still exists"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 8: guard_db.js blocks direct sqlite3 access to scrum_crm ---
scenario_08_guard_blocks_direct_sqlite3() {
  local scenario_name="8: guard_db.js blocks direct sqlite3 access to scrum_crm (exit 2)"

  # settings.json's PreToolUse hook is claude/hooks/guard_db.js — the only
  # DB entrypoint since v0.2.0 is node scrum_crm/crm.mjs db "SQL".
  local stderr_file_js
  stderr_file_js="$(mktemp)"
  local exit_code_js=0
  echo '{"tool_input":{"command":"sqlite3 scrum_crm/crm.db \"SELECT 1\""}}' | node "$GUARD_DB_JS" >/dev/null 2>"$stderr_file_js" || exit_code_js=$?
  local stderr_content_js
  stderr_content_js="$(cat "$stderr_file_js")"
  rm -f "$stderr_file_js"

  if [[ "$exit_code_js" -ne 2 ]]; then
    report_fail "$scenario_name" "guard_db.js: expected exit 2, got $exit_code_js"
    return
  fi
  if [[ "$stderr_content_js" != *"crm.mjs db"* || "$stderr_content_js" != *"CRM"* ]]; then
    report_fail "$scenario_name" "guard_db.js: stderr must mention CRM and crm.mjs db, got: '$stderr_content_js'"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 9: guard_db.js allows the canonical crm.mjs db entrypoint; blocks crm.db tampering ---
scenario_09_guard_allows_crm_mjs_db() {
  local scenario_name="9: guard_db.js allows node crm.mjs db (exit 0), blocks rm/mv/redirect on crm.db (exit 2)"

  # guard_db.js is the hook actually wired into settings.json's
  # PreToolUse — check it allows the crm.mjs entrypoint with the same
  # semantics its bash-era predecessor (db.sh, now removed) had.
  local exit_code_allow_js=0
  echo '{"tool_input":{"command":"node scrum_crm/crm.mjs db \"SELECT 1\""}}' | node "$GUARD_DB_JS" >/dev/null 2>/dev/null || exit_code_allow_js=$?

  if [[ "$exit_code_allow_js" -ne 0 ]]; then
    report_fail "$scenario_name" "guard_db.js: crm.mjs db call expected exit 0, got $exit_code_allow_js"
    return
  fi

  # guard_db.js also guards crm.db against rm/mv/redirect tampering,
  # even outside a plain sqlite3 invocation.
  local rm_stderr rm_exit
  rm_stderr="$(mktemp)"
  rm_exit=0
  echo '{"tool_input":{"command":"rm scrum_crm/crm.db"}}' | node "$GUARD_DB_JS" >/dev/null 2>"$rm_stderr" || rm_exit=$?
  local rm_stderr_content
  rm_stderr_content="$(cat "$rm_stderr")"
  rm -f "$rm_stderr"
  if [[ "$rm_exit" -ne 2 ]]; then
    report_fail "$scenario_name" "guard_db.js: rm crm.db expected exit 2, got $rm_exit"
    return
  fi
  if [[ "$rm_stderr_content" != *"crm.db"* ]]; then
    report_fail "$scenario_name" "guard_db.js: rm crm.db stderr must mention crm.db, got: '$rm_stderr_content'"
    return
  fi

  local mv_exit=0
  echo '{"tool_input":{"command":"mv scrum_crm/crm.db /tmp/stolen.db"}}' | node "$GUARD_DB_JS" >/dev/null 2>/dev/null || mv_exit=$?
  if [[ "$mv_exit" -ne 2 ]]; then
    report_fail "$scenario_name" "guard_db.js: mv crm.db expected exit 2, got $mv_exit"
    return
  fi

  local redirect_exit=0
  echo '{"tool_input":{"command":"echo garbage > scrum_crm/crm.db"}}' | node "$GUARD_DB_JS" >/dev/null 2>/dev/null || redirect_exit=$?
  if [[ "$redirect_exit" -ne 2 ]]; then
    report_fail "$scenario_name" "guard_db.js: redirect > crm.db expected exit 2, got $redirect_exit"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 10: crm.mjs sweep frees stale claims ---
scenario_10_lease_sweep_frees_stale_locks() {
  local scenario_name="10: crm.mjs sweep reverts CODING to READY_FOR_DEV and releases the TESTING claim"
  reset_database

  # Task A: CODING with a snapshot, a modified file, and a stale locked_at.
  local task_coding
  task_coding="$(insert_task 'Stale coding task' 'PLANNING' 0)"
  move_task_through_chain "$task_coding" READY_FOR_DEV CODING

  local coding_relative_path="scratch_test/lease_a.txt"
  local coding_absolute_path="$SCRATCH_DIR/$coding_relative_path"
  mkdir -p "$(dirname "$coding_absolute_path")"
  printf 'A' > "$coding_absolute_path"
  "${DB[@]}" "INSERT INTO task_files (task_id, path) VALUES (?, ?)" "$task_coding" "$coding_relative_path" >/dev/null
  "${SNAPSHOT[@]}" "$task_coding"
  printf 'B' > "$coding_absolute_path"

  "${DB[@]}" "UPDATE tasks SET assigned_agent='dev_stale', locked_at=datetime('now', ?) WHERE id=?" \
    "$LEASE_STALE_OFFSET" "$task_coding" >/dev/null

  # Task B: stale TESTING claim — the task returns to the READY_FOR_TEST queue.
  local task_need_tests
  task_need_tests="$(insert_task 'Stale need_tests task' 'PLANNING' 0)"
  move_task_through_chain "$task_need_tests" READY_FOR_DEV CODING READY_FOR_TEST TESTING
  "${DB[@]}" "UPDATE tasks SET assigned_agent='qa_stale', locked_at=datetime('now', ?) WHERE id=?" \
    "$LEASE_STALE_OFFSET" "$task_need_tests" >/dev/null

  "${LEASE_SWEEP[@]}" "$LEASE_STALE_MINUTES" >/dev/null

  local coding_content_after coding_status_after coding_agent_after
  coding_content_after="$(cat "$coding_absolute_path")"
  coding_status_after="$(select_scalar_field "SELECT status FROM tasks WHERE id=?" "$task_coding")"
  coding_agent_after="$(select_scalar_field "SELECT COALESCE(assigned_agent, '') FROM tasks WHERE id=?" "$task_coding")"

  if [[ "$coding_content_after" != "A" ]]; then
    report_fail "$scenario_name" "the CODING task's file must revert to 'A', contains '$coding_content_after'"
    return
  fi
  if [[ "$coding_status_after" != "READY_FOR_DEV" ]]; then
    report_fail "$scenario_name" "the CODING task must move to READY_FOR_DEV, status '$coding_status_after'"
    return
  fi
  if [[ -n "$coding_agent_after" ]]; then
    report_fail "$scenario_name" "the CODING task's assigned_agent must be NULL, got '$coding_agent_after'"
    return
  fi

  local need_tests_status_after need_tests_agent_after
  need_tests_status_after="$(select_scalar_field "SELECT status FROM tasks WHERE id=?" "$task_need_tests")"
  need_tests_agent_after="$(select_scalar_field "SELECT COALESCE(assigned_agent, '') FROM tasks WHERE id=?" "$task_need_tests")"

  if [[ "$need_tests_status_after" != "READY_FOR_TEST" ]]; then
    report_fail "$scenario_name" "the stale TESTING task must return to READY_FOR_TEST, became '$need_tests_status_after'"
    return
  fi
  if [[ -n "$need_tests_agent_after" ]]; then
    report_fail "$scenario_name" "the TESTING task's assigned_agent must be NULL, got '$need_tests_agent_after'"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 11: crm.mjs claim review moves to REVIEWING, review transitions, CHECK rejects READY_FOR_FIX ---
scenario_11_review_claim_and_check_constraint() {
  local scenario_name="11: crm.mjs claim review moves READY_FOR_REVIEW->REVIEWING; REVIEWING transitions; CHECK rejects READY_FOR_FIX"
  reset_database

  # a) crm.mjs claim review atomically moves READY_FOR_REVIEW -> REVIEWING and sets the agent.
  local task_review
  task_review="$(insert_task 'Review task' 'PLANNING' 0)"
  move_task_through_chain "$task_review" READY_FOR_DEV CODING READY_FOR_REVIEW

  local claim_review
  claim_review="$("${CLAIM[@]}" review)"
  if [[ "$claim_review" != "$task_review"* ]]; then
    report_fail "$scenario_name" "crm.mjs claim review expected to claim task_id=$task_review, got '$claim_review'"
    return
  fi

  local status_after_review_claim agent_after_review_claim
  status_after_review_claim="$(select_scalar_field "SELECT status FROM tasks WHERE id=?" "$task_review")"
  agent_after_review_claim="$(select_scalar_field "SELECT COALESCE(assigned_agent, '') FROM tasks WHERE id=?" "$task_review")"
  if [[ "$status_after_review_claim" != "REVIEWING" ]]; then
    report_fail "$scenario_name" "crm.mjs claim review must move the task to REVIEWING, status became '$status_after_review_claim'"
    return
  fi
  if [[ -z "$agent_after_review_claim" ]]; then
    report_fail "$scenario_name" "crm.mjs claim review must set assigned_agent, got empty"
    return
  fi

  # b) REVIEWING -> READY_FOR_TEST is legal (review passed).
  local stderr_file_pass exit_code_pass
  stderr_file_pass="$(mktemp)"
  exit_code_pass=0
  "${DB[@]}" "UPDATE tasks SET status='READY_FOR_TEST' WHERE id=?" "$task_review" >/dev/null 2>"$stderr_file_pass" || exit_code_pass=$?
  local stderr_content_pass
  stderr_content_pass="$(cat "$stderr_file_pass")"
  rm -f "$stderr_file_pass"
  if [[ "$exit_code_pass" -ne 0 ]]; then
    report_fail "$scenario_name" "REVIEWING->READY_FOR_TEST expected to be legal (exit 0), got $exit_code_pass, stderr: '$stderr_content_pass'"
    return
  fi

  # c) READY_FOR_REVIEW may only go through REVIEWING: the direct
  # READY_FOR_REVIEW -> READY_FOR_TEST jump is rejected by the trigger,
  # while REVIEWING -> READY_FOR_DEV (rework) is legal.
  local task_rework
  task_rework="$(insert_task 'Rework task' 'PLANNING' 0)"
  move_task_through_chain "$task_rework" READY_FOR_DEV CODING READY_FOR_REVIEW

  local stderr_file_skip exit_code_skip
  stderr_file_skip="$(mktemp)"
  exit_code_skip=0
  "${DB[@]}" "UPDATE tasks SET status='READY_FOR_TEST' WHERE id=?" "$task_rework" >/dev/null 2>"$stderr_file_skip" || exit_code_skip=$?
  local stderr_content_skip
  stderr_content_skip="$(cat "$stderr_file_skip")"
  rm -f "$stderr_file_skip"
  if [[ "$exit_code_skip" -eq 0 || "$stderr_content_skip" != *"Invalid status transition"* ]]; then
    report_fail "$scenario_name" "READY_FOR_REVIEW->READY_FOR_TEST must be rejected (only via REVIEWING), exit $exit_code_skip, stderr: '$stderr_content_skip'"
    return
  fi

  move_task_through_chain "$task_rework" REVIEWING

  local stderr_file_rework exit_code_rework
  stderr_file_rework="$(mktemp)"
  exit_code_rework=0
  "${DB[@]}" "UPDATE tasks SET status='READY_FOR_DEV' WHERE id=?" "$task_rework" >/dev/null 2>"$stderr_file_rework" || exit_code_rework=$?
  local stderr_content_rework
  stderr_content_rework="$(cat "$stderr_file_rework")"
  rm -f "$stderr_file_rework"
  if [[ "$exit_code_rework" -ne 0 ]]; then
    report_fail "$scenario_name" "REVIEWING->READY_FOR_DEV expected to be legal (exit 0), got $exit_code_rework, stderr: '$stderr_content_rework'"
    return
  fi

  # d) INSERT with status READY_FOR_FIX is rejected by the CHECK constraint.
  local stderr_file_check exit_code_check
  stderr_file_check="$(mktemp)"
  exit_code_check=0
  "${DB[@]}" "INSERT INTO tasks (title, description, status) VALUES ('Bad status task', 'd', 'READY_FOR_FIX')" \
    >/dev/null 2>"$stderr_file_check" || exit_code_check=$?
  local stderr_content_check
  stderr_content_check="$(cat "$stderr_file_check")"
  rm -f "$stderr_file_check"
  if [[ "$exit_code_check" -eq 0 ]]; then
    report_fail "$scenario_name" "INSERT with status READY_FOR_FIX expected a CHECK rejection, got exit 0"
    return
  fi
  if [[ "$stderr_content_check" != *"CHECK"* ]]; then
    report_fail "$scenario_name" "expected a CHECK-constraint message in stderr, got: '$stderr_content_check'"
    return
  fi

  local bad_status_count
  bad_status_count="$(select_scalar_field "SELECT COUNT(*) FROM tasks WHERE status='READY_FOR_FIX'")"
  if [[ "$bad_status_count" != "0" ]]; then
    report_fail "$scenario_name" "READY_FOR_FIX must not exist in the DB, found $bad_status_count"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 12: crm.mjs fast-open schema gate; crm.mjs batch-open empty-files gate ---
scenario_12_fast_open_and_batch_open_schema_gate() {
  local scenario_name="12: crm.mjs fast-open schema gate (G-W-T, non-empty files); crm.mjs batch-open rejects empty files"
  reset_database

  # a) crm.mjs fast-open without Given/When/Then in description -> exit 1, "schema gate" in stderr.
  local stderr_file_a exit_code_a
  stderr_file_a="$(mktemp)"
  exit_code_a=0
  "${FAST_OPEN[@]}" 'No GWT title' 'just a plain description, no acceptance criteria' 'src/a.js' \
    >/dev/null 2>"$stderr_file_a" || exit_code_a=$?
  local stderr_content_a
  stderr_content_a="$(cat "$stderr_file_a")"
  rm -f "$stderr_file_a"

  if [[ "$exit_code_a" -ne 1 ]]; then
    report_fail "$scenario_name" "crm.mjs fast-open without G-W-T: expected exit 1, got $exit_code_a"
    return
  fi
  if [[ "$stderr_content_a" != *"schema gate"* ]]; then
    report_fail "$scenario_name" "crm.mjs fast-open without G-W-T: expected 'schema gate' in stderr, got: '$stderr_content_a'"
    return
  fi

  local task_count_after_a
  task_count_after_a="$(select_scalar_field "SELECT COUNT(*) FROM tasks")"
  if [[ "$task_count_after_a" != "0" ]]; then
    report_fail "$scenario_name" "crm.mjs fast-open without G-W-T must not insert a task, found $task_count_after_a"
    return
  fi

  # b) crm.mjs fast-open WITH Given/When/Then -> creates and claims the task into CODING.
  local out_b exit_code_b
  exit_code_b=0
  out_b="$("${FAST_OPEN[@]}" 'With GWT title' 'Given a file When crm.mjs fast-open runs Then a task is created' 'src/b.js' 2>/dev/null)" \
    || exit_code_b=$?

  if [[ "$exit_code_b" -ne 0 || -z "$out_b" ]]; then
    report_fail "$scenario_name" "crm.mjs fast-open with G-W-T expected success, exit_code=$exit_code_b out='$out_b'"
    return
  fi

  local task_id_b agent_b
  task_id_b="$(echo "$out_b" | cut -d' ' -f1)"
  agent_b="$(echo "$out_b" | cut -d' ' -f2)"

  local status_b assigned_agent_b
  status_b="$(select_scalar_field "SELECT status FROM tasks WHERE id=?" "$task_id_b")"
  assigned_agent_b="$(select_scalar_field "SELECT COALESCE(assigned_agent,'') FROM tasks WHERE id=?" "$task_id_b")"
  if [[ "$status_b" != "CODING" ]]; then
    report_fail "$scenario_name" "crm.mjs fast-open with G-W-T: expected status CODING, got '$status_b'"
    return
  fi
  if [[ "$assigned_agent_b" != "$agent_b" ]]; then
    report_fail "$scenario_name" "crm.mjs fast-open with G-W-T: expected assigned_agent='$agent_b', got '$assigned_agent_b'"
    return
  fi

  # c) crm.mjs batch-open with an empty files array -> rejected, no task inserted.
  local task_count_before_c spec_file_c stderr_file_c exit_code_c
  task_count_before_c="$(select_scalar_field "SELECT COUNT(*) FROM tasks")"
  spec_file_c="$(mktemp --suffix=.json)"
  cat > "$spec_file_c" <<'EOF'
[
  {"title": "Empty files ticket", "description": "Given a spec When crm.mjs batch-open runs Then it is rejected", "files": []}
]
EOF
  stderr_file_c="$(mktemp)"
  exit_code_c=0
  "${BATCH_OPEN[@]}" "$spec_file_c" >/dev/null 2>"$stderr_file_c" || exit_code_c=$?
  local stderr_content_c
  stderr_content_c="$(cat "$stderr_file_c")"
  rm -f "$spec_file_c" "$stderr_file_c"

  if [[ "$exit_code_c" -eq 0 ]]; then
    report_fail "$scenario_name" "crm.mjs batch-open with empty files expected a non-zero exit, got 0"
    return
  fi
  if [[ "$stderr_content_c" != *"schema gate"* ]]; then
    report_fail "$scenario_name" "crm.mjs batch-open with empty files: expected 'schema gate' in stderr, got: '$stderr_content_c'"
    return
  fi

  local task_count_after_c
  task_count_after_c="$(select_scalar_field "SELECT COUNT(*) FROM tasks")"
  if [[ "$task_count_after_c" != "$task_count_before_c" ]]; then
    report_fail "$scenario_name" "crm.mjs batch-open with empty files must not insert anything, count went from $task_count_before_c to $task_count_after_c"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 13: crm.mjs event writes a trace row; crm.mjs fast-close appends an auto 'done' event ---
scenario_13_event_trace() {
  local scenario_name="13: crm.mjs event writes a queryable row; crm.mjs fast-close appends an auto kind='done' event"
  reset_database

  # a) crm.mjs event writes a row, SELECT returns it.
  local task_id_a
  task_id_a="$(insert_task 'Event task' 'PLANNING' 0)"

  if ! "${EVENT[@]}" "$task_id_a" 'test_agent' 'note' 'hello world' >/dev/null 2>&1; then
    report_fail "$scenario_name" "crm.mjs event returned non-zero for a plain insert"
    return
  fi

  local event_row
  event_row="$("${DB[@]}" "SELECT agent, kind, detail FROM events WHERE task_id=? ORDER BY id DESC LIMIT 1" "$task_id_a")"
  local event_agent event_kind event_detail
  event_agent="$(echo "$event_row" | jq -r '.[0].agent')"
  event_kind="$(echo "$event_row" | jq -r '.[0].kind')"
  event_detail="$(echo "$event_row" | jq -r '.[0].detail')"

  if [[ "$event_agent" != "test_agent" || "$event_kind" != "note" || "$event_detail" != "hello world" ]]; then
    report_fail "$scenario_name" "crm.mjs event row mismatch: agent='$event_agent' kind='$event_kind' detail='$event_detail'"
    return
  fi

  # b) crm.mjs fast-close appends an automatic kind='done' event on reaching DONE.
  local task_id_b agent_b
  task_id_b="$(insert_task 'Close task' 'CODING' 0)"
  agent_b="test_close_agent"
  "${DB[@]}" "UPDATE tasks SET assigned_agent=? WHERE id=?" "$agent_b" "$task_id_b" >/dev/null
  # crm.mjs fast-close's DoD gate now runs crm.mjs run-tests first — give it a passing
  # test file so the close reaches DONE and the auto event fires.
  write_passing_test "$task_id_b"

  local close_out_b exit_code_b
  exit_code_b=0
  close_out_b="$("${FAST_CLOSE[@]}" "$task_id_b" "$agent_b" 2>/dev/null)" || exit_code_b=$?
  if [[ "$exit_code_b" -ne 0 ]]; then
    report_fail "$scenario_name" "crm.mjs fast-close expected exit 0, got $exit_code_b, out='$close_out_b'"
    return
  fi

  local done_event_row
  done_event_row="$("${DB[@]}" "SELECT agent, kind, detail FROM events WHERE task_id=? AND kind='done' ORDER BY id DESC LIMIT 1" "$task_id_b")"
  local done_event_agent done_event_kind
  done_event_agent="$(echo "$done_event_row" | jq -r '.[0].agent')"
  done_event_kind="$(echo "$done_event_row" | jq -r '.[0].kind')"

  if [[ "$done_event_kind" != "done" || "$done_event_agent" != "$agent_b" ]]; then
    report_fail "$scenario_name" "crm.mjs fast-close must append kind='done' event with agent='$agent_b', got kind='$done_event_kind' agent='$done_event_agent'"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 14: crm.mjs fast-close git autocommit ---
scenario_14_fast_close_git_autocommit() {
  local scenario_name="14: crm.mjs fast-close commits in a git polygon; skips silently (exit 0) outside one"
  reset_database

  # a) a temporary GIT polygon: after fast-close reaches DONE, a commit
  # "crm: task <id> done" must exist.
  rm -rf "$GIT_SCRATCH_DIR"
  mkdir -p "$(dirname "$GIT_SCRATCH_DIR")"
  rsync -a --exclude='tests_selfcheck' "$SOURCE_CRM_DIR/" "$GIT_SCRATCH_DIR/"
  git -C "$GIT_SCRATCH_DIR" init -q
  git -C "$GIT_SCRATCH_DIR" config user.email 'mechanics-test@example.com'
  git -C "$GIT_SCRATCH_DIR" config user.name 'mechanics-test'

  local git_crm_mjs
  git_crm_mjs="$GIT_SCRATCH_DIR/scrum_crm/crm.mjs"
  local git_db=(node "$git_crm_mjs" db --unsafe-write)
  local git_fast_close=(node "$git_crm_mjs" fast-close)
  node "$git_crm_mjs" init >/dev/null

  # Same jest-free config.json substitution as prepare_scratch_copy — this
  # is a separate rsync copy, so it needs its own override.
  cat > "$GIT_SCRATCH_DIR/scrum_crm/config.json" <<'EOF'
{
  "testCmdTask": "node \"tests/task_{ID}.test.js\"",
  "testCmdAll": "for f in tests/task_*.test.js; do node \"$f\" || exit 1; done",
  "gitAutocommit": "auto"
}
EOF
  mkdir -p "$GIT_SCRATCH_DIR/tests"

  local task_id_a agent_a
  task_id_a="$("${git_db[@]}" --scalar "INSERT INTO tasks (title, description, status, priority) VALUES ('Git task', 'd', 'CODING', 0) RETURNING id")"
  agent_a="git_test_agent"
  "${git_db[@]}" "UPDATE tasks SET assigned_agent=? WHERE id=?" "$agent_a" "$task_id_a" >/dev/null
  # fast-close's DoD gate runs run-tests first — a passing test file
  # lets the close reach DONE so the commit actually happens.
  cat > "$GIT_SCRATCH_DIR/tests/task_${task_id_a}.test.js" <<TESTEOF
const assert = require('node:assert');
assert.strictEqual(1 + 1, 2);
TESTEOF

  local exit_code_a
  exit_code_a=0
  "${git_fast_close[@]}" "$task_id_a" "$agent_a" >/dev/null 2>/dev/null || exit_code_a=$?
  if [[ "$exit_code_a" -ne 0 ]]; then
    report_fail "$scenario_name" "fast-close in the git polygon expected exit 0, got $exit_code_a"
    rm -rf "$GIT_SCRATCH_DIR"
    return
  fi

  local commit_subject
  commit_subject="$(git -C "$GIT_SCRATCH_DIR" log -1 --pretty=%s 2>/dev/null)"
  rm -rf "$GIT_SCRATCH_DIR"

  if [[ "$commit_subject" != "crm: task $task_id_a done" ]]; then
    report_fail "$scenario_name" "expected the last commit subject 'crm: task $task_id_a done', got '$commit_subject'"
    return
  fi

  # b) a non-git polygon (the regular scratch copy) with gitAutocommit='auto'
  # (config.json's default from prepare_scratch_copy) -> fast-close still
  # succeeds, no commit attempted.
  if git -C "$SCRATCH_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    report_fail "$scenario_name" "test setup invariant broken: $SCRATCH_DIR is unexpectedly a git work tree"
    return
  fi

  local task_id_b agent_b
  task_id_b="$(insert_task 'Non-git close task' 'CODING' 0)"
  agent_b="nongit_test_agent"
  "${DB[@]}" "UPDATE tasks SET assigned_agent=? WHERE id=?" "$agent_b" "$task_id_b" >/dev/null
  write_passing_test "$task_id_b"

  local stdout_b exit_code_b
  exit_code_b=0
  stdout_b="$("${FAST_CLOSE[@]}" "$task_id_b" "$agent_b" 2>/dev/null)" || exit_code_b=$?
  if [[ "$exit_code_b" -ne 0 ]]; then
    report_fail "$scenario_name" "fast-close outside a git repo (gitAutocommit=auto) expected exit 0, got $exit_code_b"
    return
  fi
  if [[ "$stdout_b" != "DONE $task_id_b" ]]; then
    report_fail "$scenario_name" "fast-close outside a git repo: expected stdout 'DONE $task_id_b', got '$stdout_b'"
    return
  fi

  # c) a NESTED polygon: the project lives in a subdirectory of a larger
  # repo (mirrors the real incident — user_data nested under a repo that
  # also holds sibling projects like arbitrage/). An untracked "foreign"
  # file sits OUTSIDE the project directory. After fast-close, the commit
  # must contain only files under the project directory, and the foreign
  # file must remain untouched/uncommitted.
  rm -rf "$GIT_NESTED_SCRATCH_DIR"
  local outer_dir project_dir
  outer_dir="$GIT_NESTED_SCRATCH_DIR/outer"
  project_dir="$outer_dir/nested/project"
  mkdir -p "$(dirname "$project_dir")"
  git -C "$outer_dir" init -q 2>/dev/null || { mkdir -p "$outer_dir"; git -C "$outer_dir" init -q; }
  git -C "$outer_dir" config user.email 'mechanics-test@example.com'
  git -C "$outer_dir" config user.name 'mechanics-test'

  local foreign_file
  foreign_file="$outer_dir/foreign.txt"
  echo "unrelated sibling-project work, must not be swept in" > "$foreign_file"

  rsync -a --exclude='tests_selfcheck' "$SOURCE_CRM_DIR/" "$project_dir/"
  local nested_crm_mjs
  nested_crm_mjs="$project_dir/scrum_crm/crm.mjs"
  node "$nested_crm_mjs" init >/dev/null
  cat > "$project_dir/scrum_crm/config.json" <<'EOF'
{
  "testCmdTask": "node \"tests/task_{ID}.test.js\"",
  "testCmdAll": "for f in tests/task_*.test.js; do node \"$f\" || exit 1; done",
  "gitAutocommit": "auto"
}
EOF
  mkdir -p "$project_dir/tests"

  local nested_db=(node "$nested_crm_mjs" db --unsafe-write)
  local nested_fast_close=(node "$nested_crm_mjs" fast-close)
  local task_id_c agent_c
  task_id_c="$("${nested_db[@]}" --scalar "INSERT INTO tasks (title, description, status, priority) VALUES ('Nested git task', 'd', 'CODING', 0) RETURNING id")"
  agent_c="nested_git_test_agent"
  "${nested_db[@]}" "UPDATE tasks SET assigned_agent=? WHERE id=?" "$agent_c" "$task_id_c" >/dev/null
  cat > "$project_dir/tests/task_${task_id_c}.test.js" <<TESTEOF
const assert = require('node:assert');
assert.strictEqual(1 + 1, 2);
TESTEOF

  local exit_code_c
  exit_code_c=0
  "${nested_fast_close[@]}" "$task_id_c" "$agent_c" >/dev/null 2>/dev/null || exit_code_c=$?
  if [[ "$exit_code_c" -ne 0 ]]; then
    report_fail "$scenario_name" "fast-close in the nested git polygon expected exit 0, got $exit_code_c"
    rm -rf "$GIT_NESTED_SCRATCH_DIR"
    return
  fi

  local nested_commit_subject
  nested_commit_subject="$(git -C "$outer_dir" log -1 --pretty=%s 2>/dev/null)"
  if [[ "$nested_commit_subject" != "crm: task $task_id_c done" ]]; then
    report_fail "$scenario_name" "nested polygon: expected the last commit subject 'crm: task $task_id_c done', got '$nested_commit_subject'"
    rm -rf "$GIT_NESTED_SCRATCH_DIR"
    return
  fi

  local committed_files
  committed_files="$(git -C "$outer_dir" show --name-only --pretty=format: HEAD 2>/dev/null)"
  if echo "$committed_files" | grep -qx 'foreign.txt'; then
    report_fail "$scenario_name" "nested polygon: commit swept in the foreign file outside the project directory"
    rm -rf "$GIT_NESTED_SCRATCH_DIR"
    return
  fi
  if ! echo "$committed_files" | grep -q '^nested/project/'; then
    report_fail "$scenario_name" "nested polygon: commit does not contain any project-directory file, got: $committed_files"
    rm -rf "$GIT_NESTED_SCRATCH_DIR"
    return
  fi

  local foreign_status
  foreign_status="$(git -C "$outer_dir" status --porcelain -- foreign.txt)"
  rm -rf "$GIT_NESTED_SCRATCH_DIR"
  if [[ "$foreign_status" != '?? foreign.txt' ]]; then
    report_fail "$scenario_name" "nested polygon: expected foreign.txt to remain untracked ('?? foreign.txt'), got '$foreign_status'"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 15: DoD gate — red/missing test blocks crm.mjs fast-close and crm.mjs batch-close ---
scenario_15_dod_gate_blocks_red_close() {
  local scenario_name="15: DoD gate blocks crm.mjs fast-close/crm.mjs batch-close on a red or missing test suite"
  reset_database

  # a) crm.mjs fast-close on a task with a FAILING test -> exit 1, "DoD gate" in
  # stderr, status stays CODING, a kind='blocker' event is logged.
  local task_id_a agent_a
  task_id_a="$(insert_task 'DoD red task' 'CODING' 0)"
  agent_a="dod_red_agent"
  "${DB[@]}" "UPDATE tasks SET assigned_agent=? WHERE id=?" "$agent_a" "$task_id_a" >/dev/null
  write_failing_test "$task_id_a"

  local stderr_file_a exit_code_a
  stderr_file_a="$(mktemp)"
  exit_code_a=0
  "${FAST_CLOSE[@]}" "$task_id_a" "$agent_a" >/dev/null 2>"$stderr_file_a" || exit_code_a=$?
  local stderr_content_a
  stderr_content_a="$(cat "$stderr_file_a")"
  rm -f "$stderr_file_a"

  if [[ "$exit_code_a" -ne 1 ]]; then
    report_fail "$scenario_name" "crm.mjs fast-close on a red test: expected exit 1, got $exit_code_a"
    return
  fi
  if [[ "$stderr_content_a" != *"DoD gate"* ]]; then
    report_fail "$scenario_name" "crm.mjs fast-close on a red test: expected 'DoD gate' in stderr, got: '$stderr_content_a'"
    return
  fi

  local status_after_a
  status_after_a="$(select_scalar_field "SELECT status FROM tasks WHERE id=?" "$task_id_a")"
  if [[ "$status_after_a" != "CODING" ]]; then
    report_fail "$scenario_name" "crm.mjs fast-close on a red test: status must stay CODING, became '$status_after_a'"
    return
  fi

  local blocker_count_a
  blocker_count_a="$(select_scalar_field "SELECT COUNT(*) FROM events WHERE task_id=? AND kind='blocker'" "$task_id_a")"
  if [[ "$blocker_count_a" != "1" ]]; then
    report_fail "$scenario_name" "crm.mjs fast-close on a red test: expected 1 kind='blocker' event, found $blocker_count_a"
    return
  fi

  # b) crm.mjs fast-close on a task with NO test file at all -> same refusal.
  local task_id_b agent_b
  task_id_b="$(insert_task 'DoD missing-test task' 'CODING' 0)"
  agent_b="dod_missing_agent"
  "${DB[@]}" "UPDATE tasks SET assigned_agent=? WHERE id=?" "$agent_b" "$task_id_b" >/dev/null
  # deliberately no tests/task_${task_id_b}.test.js

  local stderr_file_b exit_code_b
  stderr_file_b="$(mktemp)"
  exit_code_b=0
  "${FAST_CLOSE[@]}" "$task_id_b" "$agent_b" >/dev/null 2>"$stderr_file_b" || exit_code_b=$?
  local stderr_content_b
  stderr_content_b="$(cat "$stderr_file_b")"
  rm -f "$stderr_file_b"

  if [[ "$exit_code_b" -ne 1 ]]; then
    report_fail "$scenario_name" "crm.mjs fast-close with no test file: expected exit 1, got $exit_code_b"
    return
  fi
  if [[ "$stderr_content_b" != *"DoD gate"* ]]; then
    report_fail "$scenario_name" "crm.mjs fast-close with no test file: expected 'DoD gate' in stderr, got: '$stderr_content_b'"
    return
  fi

  local status_after_b
  status_after_b="$(select_scalar_field "SELECT status FROM tasks WHERE id=?" "$task_id_b")"
  if [[ "$status_after_b" != "CODING" ]]; then
    report_fail "$scenario_name" "crm.mjs fast-close with no test file: status must stay CODING, became '$status_after_b'"
    return
  fi

  # c) crm.mjs batch-close with a red combined suite -> exit 1, no status touched.
  local task_c1 task_c2
  task_c1="$(insert_task 'Batch red task 1' 'PLANNING' 0)"
  task_c2="$(insert_task 'Batch red task 2' 'PLANNING' 0)"
  move_task_through_chain "$task_c1" READY_FOR_DEV CODING READY_FOR_TEST
  move_task_through_chain "$task_c2" READY_FOR_DEV CODING READY_FOR_TEST
  # one failing file anywhere under tests/ (matches TEST_CMD_ALL's glob) is
  # enough to redden the combined suite regardless of task_c1/c2's own files.
  write_failing_test "batch_red_marker"

  local stderr_file_c exit_code_c
  stderr_file_c="$(mktemp)"
  exit_code_c=0
  "${BATCH_CLOSE[@]}" "$task_c1" "$task_c2" >/dev/null 2>"$stderr_file_c" || exit_code_c=$?
  local stderr_content_c
  stderr_content_c="$(cat "$stderr_file_c")"
  rm -f "$stderr_file_c"

  if [[ "$exit_code_c" -ne 1 ]]; then
    report_fail "$scenario_name" "crm.mjs batch-close on a red suite: expected exit 1, got $exit_code_c"
    return
  fi
  if [[ "$stderr_content_c" != *"DoD gate"* ]]; then
    report_fail "$scenario_name" "crm.mjs batch-close on a red suite: expected 'DoD gate' in stderr, got: '$stderr_content_c'"
    return
  fi

  local status_c1_after status_c2_after
  status_c1_after="$(select_scalar_field "SELECT status FROM tasks WHERE id=?" "$task_c1")"
  status_c2_after="$(select_scalar_field "SELECT status FROM tasks WHERE id=?" "$task_c2")"
  if [[ "$status_c1_after" != "READY_FOR_TEST" || "$status_c2_after" != "READY_FOR_TEST" ]]; then
    report_fail "$scenario_name" "crm.mjs batch-close on a red suite: statuses must stay READY_FOR_TEST, got '$status_c1_after' / '$status_c2_after'"
    return
  fi

  local blocker_count_c1 blocker_count_c2
  blocker_count_c1="$(select_scalar_field "SELECT COUNT(*) FROM events WHERE task_id=? AND kind='blocker'" "$task_c1")"
  blocker_count_c2="$(select_scalar_field "SELECT COUNT(*) FROM events WHERE task_id=? AND kind='blocker'" "$task_c2")"
  if [[ "$blocker_count_c1" != "1" || "$blocker_count_c2" != "1" ]]; then
    report_fail "$scenario_name" "crm.mjs batch-close on a red suite: expected 1 kind='blocker' event per task, got c1=$blocker_count_c1 c2=$blocker_count_c2"
    return
  fi

  report_pass "$scenario_name"
}

# --- Scenario 16: crm.mjs board --json (read-only board payload) ---
scenario_16_board_readonly_kanban() {
  local scenario_name="16: crm.mjs board --json exposes the board payload read-only and never mutates the DB"
  reset_database

  # a) tasks in different statuses -> the JSON payload carries every task
  # with its exact status (the web board renders columns straight from it).
  local task_todo task_wip task_done
  task_todo="$(insert_task 'Todo task' 'READY_FOR_DEV' 0)"
  task_wip="$(insert_task 'Wip task' 'PLANNING' 0)"
  move_task_through_chain "$task_wip" READY_FOR_DEV CODING
  task_done="$(insert_task 'Done task' 'PLANNING' 0)"
  move_task_through_chain "$task_done" READY_FOR_DEV CODING READY_FOR_TEST TESTING READY_FOR_DOCS DOCUMENTING DONE

  local board_summary
  board_summary="$("${BOARD[@]}" | node -e '
    const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
    console.log(data.tasks.length + "|" + data.tasks.map((t) => t.id + ":" + t.status).sort().join(" "));
  ')"

  if [[ "$board_summary" != "3|${task_todo}:READY_FOR_DEV ${task_wip}:CODING ${task_done}:DONE" ]]; then
    report_fail "$scenario_name" "board --json expected 3 tasks with exact statuses, got '$board_summary'"
    return
  fi

  # b) --task <id> shows the task fields, a Files section and a Trace section.
  "${DB[@]}" "INSERT INTO task_files (task_id, path) VALUES (?, 'card_test.txt')" "$task_todo" >/dev/null
  "${EVENT[@]}" "$task_todo" 'test_agent' 'note' 'card trace event' >/dev/null

  local card_output
  card_output="$("${BOARD_CARD[@]}" --task "$task_todo")"

  if [[ "$card_output" != *"id: $task_todo"* ]]; then
    report_fail "$scenario_name" "--task card missing 'id: $task_todo': '$card_output'"
    return
  fi
  if [[ "$card_output" != *"Files:"* || "$card_output" != *"card_test.txt"* ]]; then
    report_fail "$scenario_name" "--task card missing a Files section with card_test.txt: '$card_output'"
    return
  fi
  if [[ "$card_output" != *"Trace:"* || "$card_output" != *"card trace event"* ]]; then
    report_fail "$scenario_name" "--task card missing a Trace section with the logged event: '$card_output'"
    return
  fi

  # c) an empty DB (no tasks) renders 'board is empty'.
  reset_database
  local empty_output
  empty_output="$("${BOARD[@]}")"
  if [[ "$empty_output" != '{"tasks":[]}' ]]; then
    report_fail "$scenario_name" "empty DB expected '{\"tasks\":[]}', got '$empty_output'"
    return
  fi

  # d) a missing crm.db -> exit 1, stderr mentions crm.mjs init.
  rm -f "$SCRATCH_DIR/scrum_crm/crm.db" "$SCRATCH_DIR/scrum_crm/crm.db-wal" "$SCRATCH_DIR/scrum_crm/crm.db-shm"
  local stderr_file_missing exit_code_missing
  stderr_file_missing="$(mktemp)"
  exit_code_missing=0
  "${BOARD[@]}" >/dev/null 2>"$stderr_file_missing" || exit_code_missing=$?
  local stderr_content_missing
  stderr_content_missing="$(cat "$stderr_file_missing")"
  rm -f "$stderr_file_missing"

  if [[ "$exit_code_missing" -ne 1 ]]; then
    report_fail "$scenario_name" "missing crm.db expected exit 1, got $exit_code_missing"
    return
  fi
  if [[ "$stderr_content_missing" != *"crm.mjs"* || "$stderr_content_missing" != *"init"* ]]; then
    report_fail "$scenario_name" "missing crm.db expected a message about crm.mjs init in stderr, got: '$stderr_content_missing'"
    return
  fi

  # e) crm.mjs board must not mutate the DB — COUNT and a per-row status slice
  # taken before/after both call shapes (plain board, --task) must be identical.
  reset_database
  local mutate_task_id
  mutate_task_id="$(insert_task 'No mutation task' 'READY_FOR_DEV' 0)"

  local count_before slice_before
  count_before="$(select_scalar_field "SELECT COUNT(*) FROM tasks")"
  slice_before="$("${DB[@]}" "SELECT id, status FROM tasks ORDER BY id")"

  "${BOARD[@]}" >/dev/null
  "${BOARD_CARD[@]}" --task "$mutate_task_id" >/dev/null

  local count_after slice_after
  count_after="$(select_scalar_field "SELECT COUNT(*) FROM tasks")"
  slice_after="$("${DB[@]}" "SELECT id, status FROM tasks ORDER BY id")"

  if [[ "$count_before" != "$count_after" ]]; then
    report_fail "$scenario_name" "crm.mjs board must not change COUNT(*), was $count_before, became $count_after"
    return
  fi
  if [[ "$slice_before" != "$slice_after" ]]; then
    report_fail "$scenario_name" "crm.mjs board must not change task rows: before='$slice_before' after='$slice_after'"
    return
  fi

  report_pass "$scenario_name"
}


scenario_17_readonly_db_and_write_subcommands() {
  local scenario_name="17: db is read-only for agents; advance/return/release/add-dep enforce the write policy"
  reset_database

  local crm=(node "$SCRATCH_DIR/scrum_crm/crm.mjs")

  # a) a raw write through db without --unsafe-write is rejected with exit 4.
  local stderr_file="$SCRATCH_DIR/.readonly_stderr"
  local exit_code=0
  "${crm[@]}" db "UPDATE tasks SET status='DONE'" >/dev/null 2>"$stderr_file" || exit_code=$?
  if [[ "$exit_code" -ne 4 ]] || ! grep -q "read-only" "$stderr_file"; then
    report_fail "$scenario_name" "raw write via db expected exit 4 + read-only message, got exit $exit_code"
    return
  fi

  # b) add-task + advance --claim/--agent/--release walk the guarded path.
  local task_id
  task_id="$("${crm[@]}" add-task "T" "Given a When b Then c" --status READY_FOR_DEV)"
  "${crm[@]}" advance "$task_id" CODING --claim agent_a >/dev/null || { report_fail "$scenario_name" "advance --claim failed"; return; }
  if "${crm[@]}" advance "$task_id" READY_FOR_TEST --agent wrong_agent >/dev/null 2>&1; then
    report_fail "$scenario_name" "advance with a wrong --agent guard must fail"
    return
  fi
  "${crm[@]}" advance "$task_id" READY_FOR_TEST --agent agent_a --release >/dev/null || { report_fail "$scenario_name" "advance --release failed"; return; }

  # c) return: READY_FOR_DEV + loop_count+1 + hint + a handoff event.
  "${crm[@]}" return "$task_id" --log /tmp/x.log --hint "fix it" --by qa_x >/dev/null || { report_fail "$scenario_name" "return failed"; return; }
  local row
  row="$("${crm[@]}" db --scalar "SELECT status||'/'||loop_count||'/'||resolution_hint FROM tasks WHERE id=$task_id")"
  if [[ "$row" != "READY_FOR_DEV/1/fix it" ]]; then
    report_fail "$scenario_name" "return expected READY_FOR_DEV/1/fix it, got '$row'"
    return
  fi
  local handoff_count
  handoff_count="$("${crm[@]}" db --scalar "SELECT COUNT(*) FROM events WHERE task_id=$task_id AND kind='handoff'")"
  if [[ "$handoff_count" != "1" ]]; then
    report_fail "$scenario_name" "return must log exactly one handoff event, got $handoff_count"
    return
  fi

  # d) add-dep rejects a cycle mechanically.
  local task_b
  task_b="$("${crm[@]}" add-task "B" "Given a When b Then c" --status READY_FOR_DEV)"
  "${crm[@]}" add-dep "$task_b" "$task_id" || { report_fail "$scenario_name" "legal add-dep failed"; return; }
  if "${crm[@]}" add-dep "$task_id" "$task_b" >/dev/null 2>&1; then
    report_fail "$scenario_name" "cyclic add-dep must be rejected"
    return
  fi

  report_pass "$scenario_name"
}


scenario_18_sweep_on_claim_and_stale_marks() {
  local scenario_name="18: claim sweeps stale leases first; the board flags stale claims for CODING/REVIEWING/TESTING/DOCUMENTING"
  reset_database

  local crm=(node "$SCRATCH_DIR/scrum_crm/crm.mjs")

  # Four tasks parked in the four in-progress stages with dead claims.
  "${crm[@]}" add-task "A" "Given a When b Then c" --status READY_FOR_DEV >/dev/null
  "${crm[@]}" add-task "B" "Given a When b Then c" --status READY_FOR_DEV >/dev/null
  "${crm[@]}" add-task "C" "Given a When b Then c" --status READY_FOR_DEV >/dev/null
  "${crm[@]}" add-task "D" "Given a When b Then c" --status READY_FOR_DEV >/dev/null
  "${crm[@]}" advance 1 CODING --claim dead1 >/dev/null
  "${crm[@]}" advance 2 CODING >/dev/null
  "${crm[@]}" advance 2 READY_FOR_TEST >/dev/null
  "${crm[@]}" advance 2 TESTING --claim dead2 >/dev/null
  local st
  for st in CODING READY_FOR_TEST TESTING READY_FOR_DOCS; do "${crm[@]}" advance 3 "$st" >/dev/null; done
  "${crm[@]}" advance 3 DOCUMENTING --claim dead3 >/dev/null
  "${crm[@]}" advance 4 CODING >/dev/null
  "${crm[@]}" advance 4 READY_FOR_REVIEW >/dev/null
  "${crm[@]}" advance 4 REVIEWING --claim dead4 >/dev/null
  "${DB[@]}" "UPDATE tasks SET locked_at=datetime('now','-2 hours')" >/dev/null
  # The claims above were made by THIS (alive) session; liveness would keep
  # them. Simulate dead holder sessions: nonexistent pid + mismatched start.
  "${DB[@]}" "UPDATE tasks SET holder_pid=4194000, holder_start='1'" >/dev/null

  # a) the board payload flags every stale claim.
  local stale_ids
  stale_ids="$("${BOARD[@]}" | node -e '
    const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
    console.log(data.tasks.filter((t) => t.stale).map((t) => t.id).sort().join(" "));
  ')"
  if [[ "$stale_ids" != "1 2 3 4" ]]; then
    report_fail "$scenario_name" "expected tasks 1-4 flagged stale in board --json, got '$stale_ids'"
    return
  fi

  # b) a single claim call sweeps all four back to their queues. claim dev:
  # after the sweep task 1 is back in READY_FOR_DEV, so the same call then
  # legitimately claims it into CODING — that re-claim is asserted too.
  "${crm[@]}" claim dev >/dev/null 2>&1 || true
  local states
  states="$("${crm[@]}" db --scalar "SELECT group_concat(status || '/' || CASE WHEN assigned_agent IS NULL THEN '-' ELSE 'claimed' END, ' ') FROM tasks ORDER BY id")"
  if [[ "$states" != "CODING/claimed READY_FOR_TEST/- READY_FOR_DOCS/- READY_FOR_REVIEW/-" ]]; then
    report_fail "$scenario_name" "after one claim dev expected 1 re-claimed live and 2/3/4 back in their queues unclaimed, got '$states'"
    return
  fi

  # c) after the sweep no stale flags remain (task 1 is a live claim now).
  stale_ids="$("${BOARD[@]}" | node -e '
    const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
    console.log(data.tasks.filter((t) => t.stale).map((t) => t.id).join(" "));
  ')"
  if [[ -n "$stale_ids" ]]; then
    report_fail "$scenario_name" "stale flags must disappear after the sweep, still flagged: '$stale_ids'"
    return
  fi

  report_pass "$scenario_name"
}


# --- Scenario 19: BLOCKED always carries a reason ---
scenario_19_blocked_requires_reason() {
  local scenario_name="19: BLOCKED requires a reason (advance --hint CLI-side, enforce_blocked_reason trigger DB-side)"
  reset_database

  local crm=(node "$SCRATCH_DIR/scrum_crm/crm.mjs")
  "${crm[@]}" add-task "Blockable" "Given a When b Then c" --status READY_FOR_DEV >/dev/null

  # Only live work can hit a blocker: READY_FOR_DEV -> BLOCKED is not a
  # legal transition (even with a hint), the task must be in CODING.
  local exit_code_queue=0
  "${crm[@]}" advance 1 BLOCKED --hint "some reason" >/dev/null 2>&1 || exit_code_queue=$?
  if [[ "$exit_code_queue" -eq 0 ]]; then
    report_fail "$scenario_name" "READY_FOR_DEV -> BLOCKED must be rejected (BLOCKED is reachable only from CODING)"
    return
  fi
  "${crm[@]}" advance 1 CODING >/dev/null

  # a) advance to BLOCKED without --hint is rejected before any write.
  local stderr_file exit_code
  stderr_file="$(mktemp)"
  exit_code=0
  "${crm[@]}" advance 1 BLOCKED >/dev/null 2>"$stderr_file" || exit_code=$?
  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  if [[ "$exit_code" -eq 0 || "$stderr_content" != *"--hint"* ]]; then
    report_fail "$scenario_name" "advance BLOCKED without --hint must fail mentioning --hint, exit $exit_code, stderr: '$stderr_content'"
    rm -f "$stderr_file"
    return
  fi

  # b) a raw write bypassing the CLI is stopped by the trigger backstop.
  exit_code=0
  "${DB[@]}" "UPDATE tasks SET status='BLOCKED' WHERE id=1" >/dev/null 2>"$stderr_file" || exit_code=$?
  stderr_content="$(cat "$stderr_file")"
  rm -f "$stderr_file"
  if [[ "$exit_code" -eq 0 || "$stderr_content" != *"BLOCKED requires a reason"* ]]; then
    report_fail "$scenario_name" "raw UPDATE to BLOCKED without a hint must be rejected by the trigger, exit $exit_code, stderr: '$stderr_content'"
    return
  fi

  # c) with --hint the transition passes, stores the reason, and logs a blocker event.
  "${crm[@]}" advance 1 BLOCKED --hint "waiting for API key rotation" >/dev/null
  local blocked_row
  blocked_row="$("${crm[@]}" db --scalar "SELECT status || '|' || resolution_hint FROM tasks WHERE id=1")"
  if [[ "$blocked_row" != "BLOCKED|waiting for API key rotation" ]]; then
    report_fail "$scenario_name" "expected BLOCKED with the stored reason, got '$blocked_row'"
    return
  fi
  local blocker_events
  blocker_events="$("${crm[@]}" db --scalar "SELECT COUNT(*) FROM events WHERE task_id=1 AND kind='blocker' AND detail LIKE 'blocked:%'")"
  if [[ "$blocker_events" != "1" ]]; then
    report_fail "$scenario_name" "expected exactly one kind='blocker' event, got '$blocker_events'"
    return
  fi

  # d) the only way back is BLOCKED -> PLANNING (reformulate the task);
  # a straight jump into the dev queue is rejected.
  local exit_code_skip_back=0
  "${crm[@]}" advance 1 READY_FOR_DEV >/dev/null 2>&1 || exit_code_skip_back=$?
  if [[ "$exit_code_skip_back" -eq 0 ]]; then
    report_fail "$scenario_name" "BLOCKED -> READY_FOR_DEV must be rejected (only exit is PLANNING)"
    return
  fi
  local exit_code_back=0
  "${crm[@]}" advance 1 PLANNING >/dev/null 2>&1 || exit_code_back=$?
  "${crm[@]}" append-desc 1 "UNBLOCKED (reformulated): rotate the key first" >/dev/null
  local status_back
  status_back="$("${crm[@]}" db --scalar "SELECT status FROM tasks WHERE id=1")"
  if [[ "$exit_code_back" -ne 0 || "$status_back" != "PLANNING" ]]; then
    report_fail "$scenario_name" "BLOCKED -> PLANNING expected to be legal, exit $exit_code_back, status '$status_back'"
    return
  fi
  "${crm[@]}" advance 1 READY_FOR_DEV >/dev/null

  report_pass "$scenario_name"
}


# --- Scenario 20: batch-claim / batch-advance are atomic group operations ---
scenario_20_batch_claim_and_advance_atomic() {
  local scenario_name="20: batch-claim/batch-advance claim and advance a whole group in one all-or-nothing transaction"
  reset_database

  local crm=(node "$SCRATCH_DIR/scrum_crm/crm.mjs")
  local task
  for task in A B C; do
    "${crm[@]}" add-task "$task" "Given a When b Then c" --status READY_FOR_DEV >/dev/null
  done

  # a) one call claims the whole group: output "AGENT id id id", every task
  # CODING under the same agent with a lease set.
  local out
  out="$("${crm[@]}" batch-claim 1 2 3)"
  local agent="${out%% *}"
  if [[ "$out" != "$agent 1 2 3" || -z "$agent" ]]; then
    report_fail "$scenario_name" "batch-claim expected 'AGENT 1 2 3', got '$out'"
    return
  fi
  local claimed_state
  claimed_state="$("${crm[@]}" db --scalar "SELECT group_concat(status || '/' || assigned_agent || '/' || (locked_at IS NOT NULL), ' ') FROM tasks ORDER BY id")"
  if [[ "$claimed_state" != "CODING/$agent/1 CODING/$agent/1 CODING/$agent/1" ]]; then
    report_fail "$scenario_name" "after batch-claim expected all three CODING under $agent with leases, got '$claimed_state'"
    return
  fi

  # b) atomicity of batch-claim: one busy id aborts the whole call and
  # NOTHING is claimed.
  reset_database
  for task in A B C; do
    "${crm[@]}" add-task "$task" "Given a When b Then c" --status READY_FOR_DEV >/dev/null
  done
  "${crm[@]}" advance 2 CODING --claim other_agent >/dev/null

  local stderr_file exit_code
  stderr_file="$(mktemp)"
  exit_code=0
  "${crm[@]}" batch-claim 1 2 3 >/dev/null 2>"$stderr_file" || exit_code=$?
  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  rm -f "$stderr_file"
  if [[ "$exit_code" -eq 0 || "$stderr_content" != *"task 2"* ]]; then
    report_fail "$scenario_name" "batch-claim with a busy id must fail naming task 2, exit $exit_code, stderr: '$stderr_content'"
    return
  fi
  local untouched
  untouched="$("${crm[@]}" db --scalar "SELECT COUNT(*) FROM tasks WHERE id IN (1,3) AND status='READY_FOR_DEV' AND assigned_agent IS NULL")"
  if [[ "$untouched" != "2" ]]; then
    report_fail "$scenario_name" "after the aborted batch-claim tasks 1 and 3 must stay READY_FOR_DEV unclaimed, untouched=$untouched"
    return
  fi

  # c) batch-advance: wrong agent -> whole batch rejected; right agent ->
  # both ids advance and release in one call.
  reset_database
  for task in A B; do
    "${crm[@]}" add-task "$task" "Given a When b Then c" --status READY_FOR_DEV >/dev/null
  done
  out="$("${crm[@]}" batch-claim 1 2)"
  agent="${out%% *}"

  exit_code=0
  "${crm[@]}" batch-advance 1 2 READY_FOR_TEST --agent impostor --release >/dev/null 2>&1 || exit_code=$?
  local still_coding
  still_coding="$("${crm[@]}" db --scalar "SELECT COUNT(*) FROM tasks WHERE status='CODING'")"
  if [[ "$exit_code" -eq 0 || "$still_coding" != "2" ]]; then
    report_fail "$scenario_name" "batch-advance under a wrong agent must reject the whole batch, exit $exit_code, still_coding=$still_coding"
    return
  fi
  "${crm[@]}" batch-advance 1 2 READY_FOR_TEST --agent "$agent" --release >/dev/null
  local advanced_state
  advanced_state="$("${crm[@]}" db --scalar "SELECT group_concat(status || '/' || COALESCE(assigned_agent,'-'), ' ') FROM tasks ORDER BY id")"
  if [[ "$advanced_state" != "READY_FOR_TEST/- READY_FOR_TEST/-" ]]; then
    report_fail "$scenario_name" "batch-advance expected both released into READY_FOR_TEST, got '$advanced_state'"
    return
  fi

  # d) trigger atomicity: task 1 is parked in READY_FOR_DOCS (TESTING is
  # illegal from there), task 2 sits in READY_FOR_TEST (TESTING is legal).
  # The legal id is listed FIRST, so its update succeeds inside the
  # transaction before the illegal one aborts — the rollback must revert it.
  "${crm[@]}" advance 1 TESTING >/dev/null
  "${crm[@]}" advance 1 READY_FOR_DOCS >/dev/null
  exit_code=0
  "${crm[@]}" batch-advance 2 1 TESTING 2>/dev/null >/dev/null || exit_code=$?
  advanced_state="$("${crm[@]}" db --scalar "SELECT group_concat(status, ' ') FROM tasks ORDER BY id")"
  if [[ "$exit_code" -eq 0 || "$advanced_state" != "READY_FOR_DOCS READY_FOR_TEST" ]]; then
    report_fail "$scenario_name" "batch-advance with one illegal transition must roll back the whole batch, exit $exit_code, states '$advanced_state'"
    return
  fi

  # e) BLOCKED is per-task by design: batch-advance refuses it outright.
  exit_code=0
  "${crm[@]}" batch-advance 2 BLOCKED 2>/dev/null >/dev/null || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    report_fail "$scenario_name" "batch-advance to BLOCKED must be refused (per-task advance --hint only)"
    return
  fi

  report_pass "$scenario_name"
}


# --- Scenario 21: batch-open description_from — mechanical extraction from the backlog file ---
scenario_21_batch_open_description_from() {
  local scenario_name="21: batch-open extracts description_from line ranges mechanically; bad ranges/files/G-W-T reject the whole spec"
  reset_database

  local crm=(node "$SCRATCH_DIR/scrum_crm/crm.mjs")
  cat > "$SCRATCH_DIR/BACKLOG.md" <<'BACKLOG'
# Backlog
T1: first ticket.
Given a registered user When they log in Then a session is created.
T2: second ticket.
Given an empty cart When checkout runs Then it fails with EmptyCart.
T3: broken ticket without acceptance criteria at all.
BACKLOG

  # a) pointers extract exact slices; an inline description still works in the same spec.
  cat > "$SCRATCH_DIR/SPEC.json" <<'SPEC'
[
  {"title": "T1", "description_from": {"file": "BACKLOG.md", "lines": [2, 3]}, "files": ["a.js"]},
  {"title": "T2", "description_from": {"file": "BACKLOG.md", "lines": [4, 5]}, "files": ["b.js"]},
  {"title": "T3", "description": "Given x When y Then z", "files": ["c.js"]}
]
SPEC
  (cd "$SCRATCH_DIR" && "${crm[@]}" batch-open SPEC.json >/dev/null)
  local desc1 desc2
  desc1="$("${crm[@]}" db --scalar "SELECT description FROM tasks WHERE id=1")"
  desc2="$("${crm[@]}" db --scalar "SELECT description FROM tasks WHERE id=2")"
  if [[ "$desc1" != "T1: first ticket.
Given a registered user When they log in Then a session is created." ]]; then
    report_fail "$scenario_name" "task 1 description must be the exact extracted slice, got '$desc1'"
    return
  fi
  if [[ "$desc2" != *"EmptyCart"* ]]; then
    report_fail "$scenario_name" "task 2 description must come from lines 4-5, got '$desc2'"
    return
  fi

  # a2) pointer + inline one-line G-W-T summary are concatenated (raw
  # backlogs rarely phrase tickets as G-W-T; the summary satisfies the
  # gate while the full text stays mechanical).
  reset_database
  cat > "$SCRATCH_DIR/SPEC.json" <<'SPEC'
[
  {"title": "T3", "description_from": {"file": "BACKLOG.md", "lines": [6, 6]}, "description": "Given valid input When run Then criteria hold", "files": ["c.js"]}
]
SPEC
  (cd "$SCRATCH_DIR" && "${crm[@]}" batch-open SPEC.json >/dev/null)
  local desc3
  desc3="$("${crm[@]}" db --scalar "SELECT description FROM tasks WHERE id=1")"
  if [[ "$desc3" != "T3: broken ticket without acceptance criteria at all.

Given valid input When run Then criteria hold" ]]; then
    report_fail "$scenario_name" "pointer+summary must concatenate (full text, blank line, summary), got '$desc3'"
    return
  fi

  # b) a range beyond EOF rejects the whole spec, nothing inserted.
  reset_database
  cat > "$SCRATCH_DIR/SPEC.json" <<'SPEC'
[
  {"title": "OK", "description_from": {"file": "BACKLOG.md", "lines": [2, 3]}, "files": ["a.js"]},
  {"title": "BAD", "description_from": {"file": "BACKLOG.md", "lines": [2, 999]}, "files": ["b.js"]}
]
SPEC
  local stderr_file exit_code=0
  stderr_file="$(mktemp)"
  (cd "$SCRATCH_DIR" && "${crm[@]}" batch-open SPEC.json) >/dev/null 2>"$stderr_file" || exit_code=$?
  local stderr_content; stderr_content="$(cat "$stderr_file")"; rm -f "$stderr_file"
  local inserted; inserted="$("${crm[@]}" db --scalar "SELECT COUNT(*) FROM tasks")"
  if [[ "$exit_code" -eq 0 || "$stderr_content" != *"ticket 1"* || "$inserted" != "0" ]]; then
    report_fail "$scenario_name" "out-of-range lines must reject the whole spec naming ticket 1, exit $exit_code, inserted=$inserted, stderr: '$stderr_content'"
    return
  fi

  # c) an extracted slice without Given/When/Then is stopped by the schema gate.
  cat > "$SCRATCH_DIR/SPEC.json" <<'SPEC'
[
  {"title": "NOGWT", "description_from": {"file": "BACKLOG.md", "lines": [6, 6]}, "files": ["a.js"]}
]
SPEC
  exit_code=0
  stderr_file="$(mktemp)"
  (cd "$SCRATCH_DIR" && "${crm[@]}" batch-open SPEC.json) >/dev/null 2>"$stderr_file" || exit_code=$?
  stderr_content="$(cat "$stderr_file")"; rm -f "$stderr_file"
  if [[ "$exit_code" -eq 0 || "$stderr_content" != *"Given/When/Then"* ]]; then
    report_fail "$scenario_name" "extracted slice without G-W-T must hit the schema gate, exit $exit_code, stderr: '$stderr_content'"
    return
  fi

  # d) a missing file is rejected before any insert.
  cat > "$SCRATCH_DIR/SPEC.json" <<'SPEC'
[
  {"title": "NOFILE", "description_from": {"file": "NO_SUCH.md", "lines": [1, 2]}, "files": ["a.js"]}
]
SPEC
  exit_code=0
  (cd "$SCRATCH_DIR" && "${crm[@]}" batch-open SPEC.json) >/dev/null 2>&1 || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    report_fail "$scenario_name" "a missing description_from file must reject the spec"
    return
  fi

  report_pass "$scenario_name"
}


# --- Scenario 22: holder liveness — the OS, not the clock, decides a claim's fate ---
scenario_22_holder_liveness() {
  local scenario_name="22: claims record the holder session; an alive holder is never swept, a dead one is swept instantly, no holder falls back to leaseMinutes"
  reset_database

  local crm=(node "$SCRATCH_DIR/scrum_crm/crm.mjs")
  "${crm[@]}" add-task "L" "Given a When b Then c" --status READY_FOR_DEV >/dev/null
  "${crm[@]}" advance 1 CODING --claim live_agent >/dev/null

  # a) the claim recorded a holder (this test session), and it is alive:
  # a sweep with a ZERO-minute lease must NOT touch the task.
  local holder
  holder="$("${crm[@]}" db --scalar "SELECT COALESCE(holder_pid,0) || '/' || COALESCE(holder_start,'-') FROM tasks WHERE id=1")"
  if [[ "$holder" == "0/-" ]]; then
    report_fail "$scenario_name" "claim must record holder_pid/holder_start (got '$holder')"
    return
  fi
  "${crm[@]}" sweep 0 >/dev/null 2>&1
  local status_alive
  status_alive="$("${crm[@]}" db --scalar "SELECT status FROM tasks WHERE id=1")"
  if [[ "$status_alive" != "CODING" ]]; then
    report_fail "$scenario_name" "alive holder must survive sweep 0, status became '$status_alive'"
    return
  fi

  # b) a verifiably dead holder (impossible pid / mismatched start) is
  # swept IMMEDIATELY, fresh locked_at and a huge lease notwithstanding.
  "${DB[@]}" "UPDATE tasks SET holder_pid=4194000, holder_start='1', locked_at=datetime('now') WHERE id=1" >/dev/null
  "${crm[@]}" sweep 99999 >/dev/null 2>&1
  local status_dead
  status_dead="$("${crm[@]}" db --scalar "SELECT status || '/' || COALESCE(assigned_agent,'-') FROM tasks WHERE id=1")"
  if [[ "$status_dead" != "READY_FOR_DEV/-" ]]; then
    report_fail "$scenario_name" "dead holder must be swept instantly even with a huge lease, got '$status_dead'"
    return
  fi

  # c) no holder info (legacy claim) -> the leaseMinutes age fallback:
  # fresh claim survives, old claim is swept.
  "${DB[@]}" "UPDATE tasks SET status='CODING', assigned_agent='legacy', locked_at=datetime('now'), holder_pid=NULL, holder_start=NULL WHERE id=1" >/dev/null
  "${crm[@]}" sweep 30 >/dev/null 2>&1
  local status_fresh
  status_fresh="$("${crm[@]}" db --scalar "SELECT status FROM tasks WHERE id=1")"
  if [[ "$status_fresh" != "CODING" ]]; then
    report_fail "$scenario_name" "legacy fresh claim must survive the age fallback, got '$status_fresh'"
    return
  fi
  "${DB[@]}" "UPDATE tasks SET locked_at=datetime('now','-2 hours') WHERE id=1" >/dev/null
  "${crm[@]}" sweep 30 >/dev/null 2>&1
  local status_old
  status_old="$("${crm[@]}" db --scalar "SELECT status || '/' || COALESCE(assigned_agent,'-') FROM tasks WHERE id=1")"
  if [[ "$status_old" != "READY_FOR_DEV/-" ]]; then
    report_fail "$scenario_name" "legacy old claim must be swept by the age fallback, got '$status_old'"
    return
  fi

  report_pass "$scenario_name"
}


# --- Scenario 23: full-process pipeline — every role participates, provably ---
scenario_23_all_roles_participate() {
  local scenario_name="23: full pipeline — every role (PO/TL/dev/reviewer/QA/doc/SM) touches the task through its own channel; the DB trace proves it"
  reset_database

  local crm=(node "$SCRATCH_DIR/scrum_crm/crm.mjs")

  # product-owner: captures the story in the BACKLOG and logs it.
  "${crm[@]}" add-task "Story" "Given a shopper When checkout runs Then a receipt is produced" >/dev/null
  local backlog_status
  backlog_status="$("${crm[@]}" db --scalar "SELECT status FROM tasks WHERE id=1")"
  if [[ "$backlog_status" != "BACKLOG" ]]; then
    report_fail "$scenario_name" "a new task must land in BACKLOG, got '$backlog_status'"
    return
  fi
  "${crm[@]}" event 1 "po_sim" note "story captured from the raw request" >/dev/null

  # team-lead: takes it into PLANNING through its own claim channel, assigns
  # files, then hands the refined story to the dev queue.
  local out_plan agent_plan
  out_plan="$("${crm[@]}" claim plan)"
  agent_plan="${out_plan#* }"
  if [[ "$agent_plan" != plan_* ]]; then
    report_fail "$scenario_name" "planning must be entered via claim plan (agent 'plan_*'), got '$out_plan'"
    return
  fi
  "${crm[@]}" add-files 1 "src/checkout.js" >/dev/null
  "${crm[@]}" advance 1 READY_FOR_DEV --agent "$agent_plan" --release >/dev/null
  "${crm[@]}" event 1 "tl_sim" handoff "files assigned, moved to READY_FOR_DEV" >/dev/null

  # developer: enters ONLY via claim dev; finishes at READY_FOR_REVIEW.
  local out_dev agent_dev
  out_dev="$("${crm[@]}" claim dev)"
  agent_dev="${out_dev#* }"
  if [[ "$agent_dev" != dev_* ]]; then
    report_fail "$scenario_name" "developer must enter via claim dev (agent 'dev_*'), got '$out_dev'"
    return
  fi
  "${crm[@]}" event 1 "$agent_dev" note "implemented per AC" >/dev/null
  "${crm[@]}" advance 1 READY_FOR_REVIEW --agent "$agent_dev" --release >/dev/null

  # reviewer: ONLY via claim review (READY_FOR_REVIEW -> REVIEWING).
  local out_rev agent_rev
  out_rev="$("${crm[@]}" claim review)"
  agent_rev="${out_rev#* }"
  if [[ "$agent_rev" != review_* ]]; then
    report_fail "$scenario_name" "reviewer must enter via claim review, got '$out_rev'"
    return
  fi
  "${crm[@]}" event 1 "$agent_rev" note "review passed" >/dev/null
  "${crm[@]}" advance 1 READY_FOR_TEST --agent "$agent_rev" --release >/dev/null

  # qa: ONLY via claim qa (READY_FOR_TEST -> TESTING).
  local out_qa agent_qa
  out_qa="$("${crm[@]}" claim qa)"
  agent_qa="${out_qa#* }"
  if [[ "$agent_qa" != qa_* ]]; then
    report_fail "$scenario_name" "qa must enter via claim qa, got '$out_qa'"
    return
  fi
  "${crm[@]}" event 1 "$agent_qa" note "tests green" >/dev/null
  "${crm[@]}" advance 1 READY_FOR_DOCS --agent "$agent_qa" --release >/dev/null

  # doc-writer: ONLY via claim doc (READY_FOR_DOCS -> DOCUMENTING).
  local out_doc agent_doc
  out_doc="$("${crm[@]}" claim doc)"
  agent_doc="${out_doc#* }"
  if [[ "$agent_doc" != doc_* ]]; then
    report_fail "$scenario_name" "doc-writer must enter via claim doc, got '$out_doc'"
    return
  fi
  "${crm[@]}" event 1 "$agent_doc" note "docs written" >/dev/null
  "${crm[@]}" advance 1 DONE --agent "$agent_doc" --release >/dev/null

  # scrum-master: closes the wave (sweep is a no-op here, the event proves the pass).
  "${crm[@]}" sweep >/dev/null 2>&1
  "${crm[@]}" event 1 "sm_sim" note "wave closed, DoD suite green" >/dev/null

  # Proof from the DB, not from this script's word:
  # (1) the task reached DONE — with REVIEWING/TESTING/DOCUMENTING as the
  # only trigger-legal path from READY_FOR_REVIEW onward;
  local final_status
  final_status="$("${crm[@]}" db --scalar "SELECT status FROM tasks WHERE id=1")"
  if [[ "$final_status" != "DONE" ]]; then
    report_fail "$scenario_name" "task must end DONE, got '$final_status'"
    return
  fi
  # (2) the trace holds one entry per role — 7 distinct role prefixes;
  local roles
  roles="$("${crm[@]}" db --scalar "SELECT group_concat(DISTINCT substr(agent, 1, instr(agent||'_','_')-1)) FROM (SELECT agent FROM events WHERE task_id=1 ORDER BY agent)")"
  local role
  for role in po tl dev review qa doc sm; do
    if [[ ",$roles," != *",$role,"* ]]; then
      report_fail "$scenario_name" "role '$role' missing from the task trace (roles seen: '$roles')"
      return
    fi
  done
  # (3) the four claim-channel agents are four DIFFERENT identities.
  local distinct_claimers
  distinct_claimers="$(printf '%s\n%s\n%s\n%s\n' "$agent_dev" "$agent_rev" "$agent_qa" "$agent_doc" | sort -u | wc -l)"
  if [[ "$distinct_claimers" != "4" ]]; then
    report_fail "$scenario_name" "dev/reviewer/qa/doc must be four distinct agents, got $distinct_claimers"
    return
  fi

  report_pass "$scenario_name"
}


# --- Scenario 24: every status change is logged mechanically ---
scenario_24_status_transition_log() {
  local scenario_name="24: log_status_transition trigger records the task's full journey in events (kind='status'), no agent cooperation needed"
  reset_database

  local crm=(node "$SCRATCH_DIR/scrum_crm/crm.mjs")
  "${crm[@]}" add-task "J" "Given a When b Then c" --status READY_FOR_DEV >/dev/null
  "${crm[@]}" advance 1 CODING --claim walker >/dev/null
  local st
  for st in READY_FOR_TEST TESTING READY_FOR_DOCS DOCUMENTING DONE; do
    "${crm[@]}" advance 1 "$st" --agent walker $( [ "$st" = DONE ] && echo --release ) >/dev/null
  done

  local journey
  journey="$("${crm[@]}" db --scalar "SELECT group_concat(detail, ' | ') FROM events WHERE task_id=1 AND kind='status' ORDER BY id")"
  local expected="READY_FOR_DEV -> CODING | CODING -> READY_FOR_TEST | READY_FOR_TEST -> TESTING | TESTING -> READY_FOR_DOCS | READY_FOR_DOCS -> DOCUMENTING | DOCUMENTING -> DONE"
  if [[ "$journey" != "$expected" ]]; then
    report_fail "$scenario_name" "expected the exact journey '$expected', got '$journey'"
    return
  fi

  # The logging is a side effect of the UPDATE itself — a raw write that
  # bypasses every CLI path is still recorded.
  reset_database
  "${crm[@]}" add-task "R" "Given a When b Then c" --status READY_FOR_DEV >/dev/null
  "${DB[@]}" "UPDATE tasks SET status='CODING' WHERE id=1" >/dev/null
  local raw_logged
  raw_logged="$("${crm[@]}" db --scalar "SELECT COUNT(*) FROM events WHERE task_id=1 AND kind='status' AND detail='READY_FOR_DEV -> CODING'")"
  if [[ "$raw_logged" != "1" ]]; then
    report_fail "$scenario_name" "a raw UPDATE must be logged too, got count=$raw_logged"
    return
  fi

  report_pass "$scenario_name"
}


# --- Scenario 25: installer never overwrites the project's own instructions ---
scenario_25_installer_host_claude_md() {
  local scenario_name="25: installer detects the host instruction file in either location (CLAUDE.md or .claude/CLAUDE.md), imports instead of overwriting, idempotently"
  local install_root="$TEST_TMP_ROOT/install_hosts"
  rm -rf "$install_root"
  local init_js="$SOURCE_CRM_DIR/bin/init.js"

  # a) rules in .claude/CLAUDE.md — the contract must NOT land in a second
  # root CLAUDE.md; it goes to CLAUDE.scrum.md, imported with a ../ path.
  mkdir -p "$install_root/dotclaude/.claude"
  printf '# Host rules\nrule one\n' > "$install_root/dotclaude/.claude/CLAUDE.md"
  node "$init_js" "$install_root/dotclaude" --yes >/dev/null 2>&1
  if [[ -f "$install_root/dotclaude/CLAUDE.md" ]]; then
    report_fail "$scenario_name" "a .claude/CLAUDE.md host must not get a second contract at the project root"
    return
  fi
  if [[ ! -f "$install_root/dotclaude/.claude/CLAUDE.scrum.md" ]]; then
    report_fail "$scenario_name" "the contract must sit beside its host: .claude/CLAUDE.scrum.md missing"
    return
  fi
  if [[ -f "$install_root/dotclaude/CLAUDE.scrum.md" ]]; then
    report_fail "$scenario_name" "no stray CLAUDE.scrum.md may be left at the project root"
    return
  fi
  if ! grep -q '^@CLAUDE\.scrum\.md$' "$install_root/dotclaude/.claude/CLAUDE.md"; then
    report_fail "$scenario_name" "expected a plain '@CLAUDE.scrum.md' import, got: '$(tail -1 "$install_root/dotclaude/.claude/CLAUDE.md")'"
    return
  fi
  if ! grep -q 'rule one' "$install_root/dotclaude/.claude/CLAUDE.md"; then
    report_fail "$scenario_name" "the host's own rules must survive"
    return
  fi

  # b) re-running the installer must not duplicate the import.
  node "$init_js" "$install_root/dotclaude" --yes >/dev/null 2>&1
  local import_count
  import_count="$(grep -c 'CLAUDE.scrum.md' "$install_root/dotclaude/.claude/CLAUDE.md")"
  if [[ "$import_count" != "1" ]]; then
    report_fail "$scenario_name" "upgrade must keep exactly one import line, found $import_count"
    return
  fi

  # c) rules in the root CLAUDE.md — imported with a plain path.
  mkdir -p "$install_root/rootmd"
  printf '# Root rules\n' > "$install_root/rootmd/CLAUDE.md"
  node "$init_js" "$install_root/rootmd" --yes >/dev/null 2>&1
  if ! grep -q '^@CLAUDE\.scrum\.md$' "$install_root/rootmd/CLAUDE.md"; then
    report_fail "$scenario_name" "expected '@CLAUDE.scrum.md' in the root host file"
    return
  fi
  if ! grep -q 'Root rules' "$install_root/rootmd/CLAUDE.md"; then
    report_fail "$scenario_name" "the root host's own rules must survive"
    return
  fi

  # d) legacy layout (contract at the root, imported with ../) is migrated
  # in place: the import loses the hop and the stray root copy is removed.
  mkdir -p "$install_root/legacy/.claude"
  printf '# Host rules\n\n# agent-scrum (imported contract)\n@../CLAUDE.scrum.md\n' > "$install_root/legacy/.claude/CLAUDE.md"
  printf 'stale contract\n' > "$install_root/legacy/CLAUDE.scrum.md"
  node "$init_js" "$install_root/legacy" --yes >/dev/null 2>&1
  if [[ -f "$install_root/legacy/CLAUDE.scrum.md" ]]; then
    report_fail "$scenario_name" "the stale root CLAUDE.scrum.md must be removed on upgrade"
    return
  fi
  local legacy_imports
  legacy_imports="$(grep -c 'CLAUDE.scrum.md' "$install_root/legacy/.claude/CLAUDE.md")"
  if [[ "$legacy_imports" != "1" ]] || ! grep -q '^@CLAUDE\.scrum\.md$' "$install_root/legacy/.claude/CLAUDE.md"; then
    report_fail "$scenario_name" "legacy '@../' import must become exactly one '@CLAUDE.scrum.md', found $legacy_imports"
    return
  fi

  # e) a project with no instructions at all gets the contract as CLAUDE.md.
  mkdir -p "$install_root/fresh"
  node "$init_js" "$install_root/fresh" --yes >/dev/null 2>&1
  if ! head -1 "$install_root/fresh/CLAUDE.md" | grep -q 'Scrum-CRM'; then
    report_fail "$scenario_name" "a fresh project must get the contract as its CLAUDE.md"
    return
  fi

  report_pass "$scenario_name"
}


# --- Scenario 26: planMode 'off' is enforced, not merely requested ---
scenario_26_plan_mode_off_blocks_batch_open() {
  local scenario_name="26: planMode 'off' makes batch-open refuse (PLAN cannot start by accident); 'auto'/'ask' let it through"
  reset_database

  local crm=(node "$SCRATCH_DIR/scrum_crm/crm.mjs")
  cat > "$SCRATCH_DIR/SPEC.json" <<'SPEC'
[
  {"title": "P", "description": "Given a When b Then c", "files": ["p.js"]}
]
SPEC

  set_config_value() {
    python3 - "$SCRATCH_DIR/scrum_crm/config.json" "$1" <<'PYCFG'
import json,sys
p=sys.argv[1]; c=json.load(open(p)); c['planMode']=sys.argv[2]
open(p,'w').write(json.dumps(c,indent=2)+'\n')
PYCFG
  }

  # a) planMode off -> batch-open refused, nothing inserted.
  set_config_value off
  local stderr_file exit_code=0
  stderr_file="$(mktemp)"
  (cd "$SCRATCH_DIR" && "${crm[@]}" batch-open SPEC.json) >/dev/null 2>"$stderr_file" || exit_code=$?
  local stderr_content; stderr_content="$(cat "$stderr_file")"; rm -f "$stderr_file"
  local inserted; inserted="$("${crm[@]}" db --scalar "SELECT COUNT(*) FROM tasks")"
  if [[ "$exit_code" -eq 0 || "$stderr_content" != *"planMode"* || "$inserted" != "0" ]]; then
    report_fail "$scenario_name" "planMode=off must refuse batch-open naming planMode, exit $exit_code, inserted=$inserted, stderr: '$stderr_content'"
    return
  fi

  # b) ask and auto both allow it (the confirmation lives in the contract,
  # not in the mechanics).
  local mode
  for mode in ask auto; do
    reset_database
    set_config_value "$mode"
    exit_code=0
    (cd "$SCRATCH_DIR" && "${crm[@]}" batch-open SPEC.json) >/dev/null 2>&1 || exit_code=$?
    inserted="$("${crm[@]}" db --scalar "SELECT COUNT(*) FROM tasks")"
    if [[ "$exit_code" -ne 0 || "$inserted" != "1" ]]; then
      report_fail "$scenario_name" "planMode=$mode must allow batch-open, exit $exit_code, inserted=$inserted"
      return
    fi
  done

  report_pass "$scenario_name"
}


# --- Scenario 27: BACKLOG/PLANNING is a queue/active pair like every other stage ---
scenario_27_backlog_planning_pair() {
  local scenario_name="27: BACKLOG is the queue, PLANNING is live refinement — claim plan moves and holds it, a dead planner is swept back to BACKLOG"
  reset_database

  local crm=(node "$SCRATCH_DIR/scrum_crm/crm.mjs")
  "${crm[@]}" add-task "Idea" "Given a When b Then c" >/dev/null

  # a) claim plan takes it BACKLOG -> PLANNING and records the holder.
  local out agent
  out="$("${crm[@]}" claim plan)"
  agent="${out#* }"
  local state
  state="$("${crm[@]}" db --scalar "SELECT status || '/' || COALESCE(assigned_agent,'-') || '/' || (holder_pid IS NOT NULL) FROM tasks WHERE id=1")"
  if [[ "$agent" != plan_* || "$state" != "PLANNING/$agent/1" ]]; then
    report_fail "$scenario_name" "claim plan must move BACKLOG->PLANNING with a holder, got '$out' / '$state'"
    return
  fi

  # b) a second planner finds nothing — the task is held, not queued twice.
  local second
  second="$("${crm[@]}" claim plan)"
  if [[ -n "$second" ]]; then
    report_fail "$scenario_name" "a claimed PLANNING task must not be claimable again, got '$second'"
    return
  fi

  # c) a dead planner's task goes back to the BACKLOG queue, unclaimed.
  "${DB[@]}" "UPDATE tasks SET holder_pid=4194000, holder_start='1' WHERE id=1" >/dev/null
  "${crm[@]}" sweep 99999 >/dev/null 2>&1
  state="$("${crm[@]}" db --scalar "SELECT status || '/' || COALESCE(assigned_agent,'-') FROM tasks WHERE id=1")"
  if [[ "$state" != "BACKLOG/-" ]]; then
    report_fail "$scenario_name" "a dead planner must release the task back to BACKLOG, got '$state'"
    return
  fi

  # d) the trigger keeps the pair honest: BACKLOG cannot skip PLANNING.
  local exit_code=0
  "${DB[@]}" "UPDATE tasks SET status='READY_FOR_DEV' WHERE id=1" >/dev/null 2>&1 || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    report_fail "$scenario_name" "BACKLOG -> READY_FOR_DEV must be rejected (planning is not optional)"
    return
  fi

  # e) refinement can also be put back: PLANNING -> BACKLOG is legal.
  "${crm[@]}" claim plan >/dev/null
  exit_code=0
  "${crm[@]}" advance 1 BACKLOG --release >/dev/null 2>&1 || exit_code=$?
  state="$("${crm[@]}" db --scalar "SELECT status FROM tasks WHERE id=1")"
  if [[ "$exit_code" -ne 0 || "$state" != "BACKLOG" ]]; then
    report_fail "$scenario_name" "PLANNING -> BACKLOG must be legal, exit $exit_code, status '$state'"
    return
  fi

  report_pass "$scenario_name"
}


# --- Scenario 28: the mechanics ledger counts what the guarantees prevented ---
scenario_28_report_ledger() {
  local scenario_name="28: every refusal is recorded and 'report' counts it — the value of the guarantees is measured, not claimed"
  reset_database

  local crm=(node "$SCRATCH_DIR/scrum_crm/crm.mjs")

  # Provoke one refusal of each kind.
  "${crm[@]}" fast-open "No criteria" "just do it" src/x.js >/dev/null 2>&1 || true            # schema gate
  "${crm[@]}" add-task "T" "Given a When b Then c" --status READY_FOR_DEV >/dev/null
  "${crm[@]}" advance 1 DONE >/dev/null 2>&1 || true                                            # illegal transition
  "${crm[@]}" advance 1 CODING >/dev/null
  "${crm[@]}" advance 1 BLOCKED >/dev/null 2>&1 || true                                         # BLOCKED without a reason
  "${DB[@]}" "UPDATE tasks SET assigned_agent='dead', locked_at=datetime('now'), holder_pid=4194000, holder_start='1' WHERE id=1" >/dev/null
  "${crm[@]}" sweep 99999 >/dev/null 2>&1                                                       # dead-holder sweep

  local json
  json="$("${crm[@]}" report 30 --json)"
  local counts
  counts="$(printf '%s' "$json" | node -e '
    const d = JSON.parse(require("fs").readFileSync(0, "utf8")).prevented;
    console.log([d.schemaGateRejections, d.illegalTransitions, d.blockedWithoutReason, d.deadHolderSweeps].join(" "));
  ')"
  if [[ "$counts" != "1 1 1 1" ]]; then
    report_fail "$scenario_name" "expected one refusal of each kind (schema/transition/blocked/sweep), got '$counts'"
    return
  fi

  # The human-readable form must show the same total and never be empty.
  local text total
  text="$("${crm[@]}" report 30)"
  total="$(printf '%s' "$json" | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).prevented.total)')"
  if [[ "$total" -lt 4 ]] || [[ "$text" != *"mechanics ledger"* ]] || [[ "$text" != *"TOTAL"* ]]; then
    report_fail "$scenario_name" "report text must show the ledger and a TOTAL of at least 4, total=$total"
    return
  fi

  # A window that predates the events must count none of them (the ledger
  # is time-scoped, not cumulative).
  reset_database
  local empty_total
  empty_total="$("${crm[@]}" report 30 --json | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).prevented.total)')"
  if [[ "$empty_total" != "0" ]]; then
    report_fail "$scenario_name" "a clean database must report zero prevented failures, got $empty_total"
    return
  fi

  report_pass "$scenario_name"
}


# --- Scenario 29: the guard hook is narrow — mentions are not attacks ---
scenario_29_guard_precision() {
  local scenario_name="29: guard_db.js blocks real access to THIS project's crm.db, and lets mere mentions, unrelated databases and throwaway copies through"

  hook_exit() {
    local command="$1"
    local payload
    payload="$(node -e 'process.stdout.write(JSON.stringify({tool_input:{command:process.argv[1]}}))' "$command")"
    local code=0
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR=/proj node "$GUARD_DB_JS" >/dev/null 2>&1 || code=$?
    echo "$code"
  }

  # Real access to the project's database stays blocked.
  local blocked_cases=(
    'sqlite3 scrum_crm/crm.db "SELECT 1"'
    'sqlite3 /proj/scrum_crm/crm.db ".dump"'
    'rm -f scrum_crm/crm.db'
    'mv scrum_crm/crm.db /tmp/stolen.db'
    'echo garbage > scrum_crm/crm.db'
  )
  local command code
  for command in "${blocked_cases[@]}"; do
    code="$(hook_exit "$command")"
    if [[ "$code" != "2" ]]; then
      report_fail "$scenario_name" "expected a block (exit 2) for: $command — got $code"
      return
    fi
  done

  # Ordinary work that merely mentions the words, touches an unrelated
  # database, or deletes a throwaway copy outside the project must pass:
  # a guard that cries wolf gets worked around.
  local allowed_cases=(
    'node scrum_crm/crm.mjs db "SELECT 1"'
    'git commit -m "docs: describe the sqlite3 and crm.db guard"'
    'python3 build.py  # this script imports sqlite3 and reads scrum_crm'
    'rm -rf /tmp/scratch && node scrum_crm/crm.mjs report'
    'rm -f /tmp/polygon/scrum_crm/crm.db'
    'sqlite3 data/app.db "SELECT 1"'
  )
  for command in "${allowed_cases[@]}"; do
    code="$(hook_exit "$command")"
    if [[ "$code" != "0" ]]; then
      report_fail "$scenario_name" "expected a pass (exit 0) for: $command — got $code"
      return
    fi
  done

  # The shipped deny rules must stay anchored to the installed copy, so a
  # nested checkout of the tool itself remains editable.
  local settings="$SOURCE_CRM_DIR/claude/settings.json"
  if grep -q '"Bash(sqlite3:\*)"' "$settings"; then
    report_fail "$scenario_name" "the blanket Bash sqlite3 deny must be gone — the hook covers the real case"
    return
  fi
  if ! grep -q '"Edit(\./scrum_crm/lib/\*\*)"' "$settings"; then
    report_fail "$scenario_name" "deny rules must be anchored with ./ so they only cover the installed copy"
    return
  fi

  report_pass "$scenario_name"
}


# --- Scenario 30: with the docs stage on, a task closes only once it says what it did ---
scenario_30_summary_gate() {
  local scenario_name="30: docs stage on -> no close without a short summary in the DB; the summary is capped and shows on the board"
  reset_database

  local crm=(node "$SCRATCH_DIR/scrum_crm/crm.mjs")
  local config="$SCRATCH_DIR/scrum_crm/config.json"
  python3 - "$config" <<'PYCFG'
import json,sys
p=sys.argv[1]; c=json.load(open(p)); c['docsEnabled']=True; c['testsEnabled']=False
open(p,'w').write(json.dumps(c,indent=2)+'\n')
PYCFG

  local out id agent
  out="$("${crm[@]}" fast-open "Summarised task" "Given a When b Then c" src/summary_demo.js)"
  id="${out%% *}"; agent="${out#* }"

  # a) closing without a summary is refused, and the refusal is recorded.
  local stderr_file exit_code=0
  stderr_file="$(mktemp)"
  "${crm[@]}" fast-close "$id" "$agent" >/dev/null 2>"$stderr_file" || exit_code=$?
  local stderr_content; stderr_content="$(cat "$stderr_file")"; rm -f "$stderr_file"
  local status_after; status_after="$("${crm[@]}" db --scalar "SELECT status FROM tasks WHERE id=$id")"
  if [[ "$exit_code" -eq 0 || "$stderr_content" != *"set-summary"* || "$status_after" != "CODING" ]]; then
    report_fail "$scenario_name" "close without a summary must be refused and change nothing, exit $exit_code, status '$status_after', stderr: '$stderr_content'"
    return
  fi
  local refusals; refusals="$("${crm[@]}" db --scalar "SELECT COUNT(*) FROM events WHERE task_id=$id AND kind='refusal' AND detail LIKE '%no summary%'")"
  if [[ "$refusals" != "1" ]]; then
    report_fail "$scenario_name" "the refusal must land in the ledger, got $refusals"
    return
  fi

  # b) empty and oversized summaries are refused by the command itself.
  exit_code=0
  "${crm[@]}" set-summary "$id" "   " >/dev/null 2>&1 || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    report_fail "$scenario_name" "an empty summary must be refused"
    return
  fi
  local long_text; long_text="$(head -c 400 < /dev/zero | tr '\0' 'x')"
  exit_code=0
  "${crm[@]}" set-summary "$id" "$long_text" >/dev/null 2>&1 || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    report_fail "$scenario_name" "a summary over the cap must be refused"
    return
  fi

  # c) with a summary the close goes through, and the board shows it.
  "${crm[@]}" set-summary "$id" "Added slug normalisation and its regression test." --agent "$agent" >/dev/null
  "${crm[@]}" fast-close "$id" "$agent" >/dev/null
  local final; final="$("${crm[@]}" db --scalar "SELECT status FROM tasks WHERE id=$id")"
  if [[ "$final" != "DONE" ]]; then
    report_fail "$scenario_name" "with a summary the task must close, status '$final'"
    return
  fi
  local on_board
  on_board="$("${crm[@]}" board --json | node -e '
    const tasks = JSON.parse(require("fs").readFileSync(0, "utf8")).tasks;
    console.log(tasks.some((t) => (t.summary || "").includes("slug normalisation")) ? "yes" : "no");
  ')"
  if [[ "$on_board" != "yes" ]]; then
    report_fail "$scenario_name" "the summary must be part of the board payload"
    return
  fi
  if ! "${crm[@]}" board --task "$id" | grep -q "summary: Added slug normalisation"; then
    report_fail "$scenario_name" "the task card must print the summary"
    return
  fi

  # d) with the docs stage off, no summary is required.
  python3 - "$config" <<'PYCFG'
import json,sys
p=sys.argv[1]; c=json.load(open(p)); c['docsEnabled']=False
open(p,'w').write(json.dumps(c,indent=2)+'\n')
PYCFG
  out="$("${crm[@]}" fast-open "Undocumented task" "Given a When b Then c" src/summary_demo2.js)"
  id="${out%% *}"; agent="${out#* }"
  exit_code=0
  "${crm[@]}" fast-close "$id" "$agent" >/dev/null 2>&1 || exit_code=$?
  final="$("${crm[@]}" db --scalar "SELECT status FROM tasks WHERE id=$id")"
  if [[ "$exit_code" -ne 0 || "$final" != "DONE" ]]; then
    report_fail "$scenario_name" "with the docs stage off a task must close without a summary, exit $exit_code, status '$final'"
    return
  fi

  report_pass "$scenario_name"
}

main() {
  trap cleanup_scratch EXIT
  prepare_scratch_copy

  scenario_01_shared_file_serialization
  scenario_02_dependency_blocks_claim
  scenario_03_parallel_claim_exclusivity
  scenario_04_cycle_detection_cte
  scenario_05_invalid_status_transition_rejected
  scenario_06_special_characters_roundtrip
  scenario_07_snapshot_restore_roundtrip
  scenario_08_guard_blocks_direct_sqlite3
  scenario_09_guard_allows_crm_mjs_db
  scenario_10_lease_sweep_frees_stale_locks
  scenario_11_review_claim_and_check_constraint
  scenario_12_fast_open_and_batch_open_schema_gate
  scenario_13_event_trace
  scenario_14_fast_close_git_autocommit
  scenario_15_dod_gate_blocks_red_close
  scenario_16_board_readonly_kanban
  scenario_17_readonly_db_and_write_subcommands
  scenario_18_sweep_on_claim_and_stale_marks
  scenario_19_blocked_requires_reason
  scenario_20_batch_claim_and_advance_atomic
  scenario_21_batch_open_description_from
  scenario_22_holder_liveness
  scenario_23_all_roles_participate
  scenario_24_status_transition_log
  scenario_25_installer_host_claude_md
  scenario_26_plan_mode_off_blocks_batch_open
  scenario_27_backlog_planning_pair
  scenario_28_report_ledger
  scenario_29_guard_precision
  scenario_30_summary_gate

  echo "----"
  echo "Total: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
  if [[ "$FAIL_COUNT" -ne 0 ]]; then
    echo "Failed scenarios: ${FAIL_NAMES[*]}"
    exit 1
  fi
  exit 0
}

main
