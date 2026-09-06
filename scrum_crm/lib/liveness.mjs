// Holder liveness: "is the claiming session still alive?" answered by the
// OS, not by a clock. At claim time we record the claiming SESSION's pid
// and its start time; the sweep then releases a claim the moment its
// holder is verifiably dead, and never touches a claim whose holder is
// verifiably alive — however long it has been thinking. leaseMinutes
// remains only the fallback for rows without holder info (legacy claims,
// platforms without /proc-style introspection).
import { readFileSync, existsSync } from 'node:fs';

// /proc/<pid>/stat: field 22 is the process start time in clock ticks
// since boot — together with the pid it identifies a process instance
// (a reused pid gets a different start time). comm (field 2) may contain
// spaces/parens, so fields are taken after the closing paren.
function processStart(pid) {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');
    const afterComm = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
    return afterComm[19]; // field 22 overall = index 19 after pid+comm+state
  } catch {
    return null;
  }
}

function parentOf(pid) {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');
    const afterComm = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
    return Number(afterComm[1]); // field 4 overall = ppid
  } catch {
    return null;
  }
}

// The CLI process (node crm.mjs ...) dies with the call; its parent is the
// tool shell, which dies with the tool call; the grandparent is the
// long-lived session process (Claude Code session, or the human's
// interactive shell). That grandparent is the holder.
export function captureHolder() {
  if (!existsSync('/proc/self/stat')) {
    return null; // no /proc (macOS/Windows) — fall back to leaseMinutes
  }
  const shellPid = process.ppid;
  const sessionPid = shellPid ? parentOf(shellPid) : null;
  if (!sessionPid || sessionPid <= 1) {
    return null;
  }
  const start = processStart(sessionPid);
  if (!start) {
    return null;
  }
  return { pid: sessionPid, start };
}

// true = alive, false = verifiably dead, null = cannot tell (no /proc).
export function isHolderAlive(pid, start) {
  if (!pid || !start || !existsSync('/proc/self/stat')) {
    return null;
  }
  const currentStart = processStart(pid);
  if (currentStart === null) {
    return false; // pid gone
  }
  return currentStart === String(start) ? true : false; // pid reused = dead
}
