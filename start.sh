#!/usr/bin/env bash
# start.sh ["request"] — console entry point.
# Without an argument: prints a usage hint. With an argument: initializes
# the DB if needed and launches claude with that request.
# dev wrapper (bash), not needed on Windows — there, run
# `node scrum_crm/crm.mjs init` and `claude "your request"` directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_SRC_DIR="$SCRIPT_DIR/claude"
CLAUDE_COPY_DIR="$SCRIPT_DIR/.claude"

# The claude CLI reads only .claude/; claude/ is the source of truth (edit
# it directly, no permission prompts), .claude/ is a generated copy.
if [[ ! -d "$CLAUDE_COPY_DIR" ]] \
   || [[ -n "$(find "$CLAUDE_SRC_DIR" -newer "$CLAUDE_COPY_DIR" -print -quit)" ]]; then
  echo "start.sh: syncing claude/ -> .claude/"
  rm -rf "$CLAUDE_COPY_DIR"
  cp -r "$CLAUDE_SRC_DIR" "$CLAUDE_COPY_DIR"
fi

if [[ ! -f "$SCRIPT_DIR/scrum_crm/crm.db" ]]; then
  echo "start.sh: crm.db not found, initializing..."
  node "$SCRIPT_DIR/scrum_crm/crm.mjs" init >/dev/null
fi

if [[ $# -ge 1 ]]; then
  exec claude "$1"
fi

cat <<'EOF'
usage:
  start.sh "request"    — sync .claude/ from claude/, initialize the DB
                           (if needed) and launch claude with the request
  claude in this folder  — compatible with the Claude Code VS Code plugin:
                           open this folder in VS Code, .claude/ is picked up
                           automatically (run start.sh at least once so that
                           .claude/ is synced with claude/)
EOF
