// Commits the target project's working tree after a task/batch reaches
// DONE. Ported from fast_close.sh/batch_close.sh's run_git_autocommit —
// same GIT_AUTOCOMMIT semantics (auto/1/0).
import { spawnSync } from 'node:child_process';
import { relative } from 'node:path';

function runGit(cwd, args) {
  return spawnSync('git', ['-C', cwd, ...args], { stdio: ['ignore', 'ignore', 'ignore'] });
}

// projectRoot can be a nested subdirectory of a larger (possibly shared)
// repo — the pathspec below keeps add/commit scoped to it, so a stray
// untracked file elsewhere in that shared repo is never swept in.
function resolveProjectPathspec(projectRoot) {
  const toplevel = spawnSync('git', ['-C', projectRoot, 'rev-parse', '--show-toplevel'], {
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  const repoToplevel = toplevel.stdout.toString().trim();
  if (toplevel.status !== 0 || !repoToplevel) {
    return { repoToplevel: projectRoot, pathspec: '.' };
  }
  const relPath = relative(repoToplevel, projectRoot);
  return { repoToplevel, pathspec: relPath === '' ? '.' : relPath };
}

export function runGitAutocommit({ projectRoot, gitAutocommit, taskIdsLabel, callerName }) {
  if (gitAutocommit === '0') {
    return;
  }

  const isWorkTree = runGit(projectRoot, ['rev-parse', '--is-inside-work-tree']);
  if (isWorkTree.status !== 0) {
    if (gitAutocommit === '1') {
      process.stderr.write(`${callerName}: GIT_AUTOCOMMIT=1 but ${projectRoot} is not a git repo\n`);
    }
    return;
  }

  const { repoToplevel, pathspec } = resolveProjectPathspec(projectRoot);

  runGit(repoToplevel, ['add', '-A', '--', pathspec]);
  const diffCached = runGit(repoToplevel, ['diff', '--cached', '--quiet', '--', pathspec]);
  if (diffCached.status === 0) {
    return;
  }

  runGit(repoToplevel, ['commit', '-m', `crm: task ${taskIdsLabel} done`, '--no-verify', '--quiet', '--', pathspec]);
}
