#!/usr/bin/env node
// PreToolUse hook (matcher: Bash). Protects THIS project's crm.db from
// direct access and corruption that bypasses `node scrum_crm/crm.mjs db`.
// Does not block `crm.mjs db` itself. Native on Windows/macOS/Linux.
//
// Deliberately narrow: it blocks a command that actually runs sqlite3 (or
// rm/mv/redirect) against a CRM database inside this project. Merely
// mentioning "sqlite3" or "crm.db" — in a script's source, a commit
// message, a changelog — is not an attack and must not be blocked, or the
// guard becomes noise people learn to work around.

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

// Shell segments: only what runs as its own command can be an invocation.
function splitSegments(command) {
  return command.split(/(?:&&|\|\||[;|\n])/);
}

const CRM_DB_PATH = /[^\s'"();|&]*crm\.db[^\s'"();|&]*/g;

// Only this project's databases are protected: a relative path, or an
// absolute one under the project directory. A crm.db copy in /tmp (a
// throwaway test polygon, someone else's project) is not our business.
function targetsThisProject(paths) {
  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  return paths.some((rawPath) => {
    const cleaned = rawPath.replace(/^["']|["']$/g, '');
    if (!cleaned.startsWith('/') && !cleaned.startsWith('~')) {
      return true;
    }
    return cleaned.startsWith(projectDir);
  });
}

function crmDbPathsIn(segment) {
  return segment.match(CRM_DB_PATH) || [];
}

// sqlite3 as the command being run (optionally via sudo/env/a full path),
// not the word appearing inside an argument or a heredoc body.
const SQLITE_INVOCATION = /^\s*(?:sudo\s+)?(?:\w+=\S+\s+)*(?:[\w./-]*\/)?sqlite3\b/;

function isDestructive(segment) {
  const removes = /(?:^|\s)(?:sudo\s+)?(?:rm|unlink|shred|truncate)\b/.test(segment);
  const moves = /(?:^|\s)(?:sudo\s+)?(?:mv|cp|dd)\b/.test(segment);
  const redirects = />\s*[^\s;|&]*crm\.db/.test(segment);
  return removes || moves || redirects;
}

async function main() {
  const raw = await readStdin();
  const command = extractCommand(raw);

  if (!command) {
    process.exit(0);
  }

  for (const segment of splitSegments(command)) {
    const dbPaths = crmDbPathsIn(segment);

    if (SQLITE_INVOCATION.test(segment) && (dbPaths.length > 0 || /scrum_crm/.test(segment))) {
      if (dbPaths.length === 0 || targetsThisProject(dbPaths)) {
        process.stderr.write('Direct sqlite3 access to this project\'s CRM database is forbidden. Use node scrum_crm/crm.mjs db "SQL" [params]\n');
        process.exit(2);
      }
    }

    if (dbPaths.length > 0 && isDestructive(segment) && targetsThisProject(dbPaths)) {
      process.stderr.write('Corrupting this project\'s crm.db is forbidden (use crm.mjs snapshot/restore, or delete a throwaway copy outside the project)\n');
      process.exit(2);
    }
  }

  process.exit(0);
}

main();
