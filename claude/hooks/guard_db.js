#!/usr/bin/env node
// PreToolUse hook (matcher: Bash). Protects crm.db from direct access
// and corruption bypassing `node scrum_crm/crm.mjs db`. Does not block
// `crm.mjs db` itself. Native on Windows/macOS/Linux (no bash/python3
// needed).

function readStdin() {
  return new Promise((resolve) => {
    let input = '';
    process.stdin.on('data', (chunk) => { input += chunk; });
    process.stdin.on('end', () => resolve(input));
    process.stdin.resume();
  });
}

function extractCommand(raw) {
  try {
    const payload = JSON.parse(raw);
    return (payload.tool_input && payload.tool_input.command) || '';
  } catch {
    return '';
  }
}

async function main() {
  const raw = await readStdin();
  const command = extractCommand(raw);

  if (!command) {
    process.exit(0);
  }

  if (command.includes('sqlite3') && command.includes('scrum_crm')) {
    process.stderr.write('Direct sqlite3 access to CRM is forbidden. Use node scrum_crm/crm.mjs db "SQL" [params]\n');
    process.exit(2);
  }

  if (command.includes('crm.db')) {
    const isRm = /(^|[;&]+\s*)rm\s/.test(command);
    const isMv = command.includes('mv ');
    const isRedirect = />\s*[^\s]*crm\.db/.test(command);
    if (isRm || isMv || isRedirect) {
      process.stderr.write('Corrupting crm.db is forbidden\n');
      process.exit(2);
    }
  }

  process.exit(0);
}

main();
