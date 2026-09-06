// snapshot(taskId) / restoreSnapshot(taskId) — save/roll back a task's
// task_files before/after an edit. Pure fs, cross-platform paths via
// node:path. Ported from snapshot.sh / restore.sh.
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { runQuery } from './db.mjs';

function listFilesRecursively(rootDir) {
  if (!existsSync(rootDir)) {
    return [];
  }
  const files = [];
  const stack = [rootDir];
  while (stack.length > 0) {
    const currentDir = stack.pop();
    for (const entry of readdirSync(currentDir, { withFileTypes: true })) {
      const entryPath = join(currentDir, entry.name);
      if (entry.isDirectory()) {
        stack.push(entryPath);
      } else {
        files.push(entryPath);
      }
    }
  }
  return files;
}

function taskFilePaths(dbPath, taskId) {
  return runQuery(dbPath, 'SELECT path FROM task_files WHERE task_id = ?', [taskId]).map((row) => row.path);
}

export function snapshot({ taskId, dbPath, crmDir, projectRoot }) {
  const snapshotDir = join(crmDir, 'snapshots', String(taskId));
  const filesDir = join(snapshotDir, 'files');
  const newFilesListPath = join(snapshotDir, 'NEW_FILES.txt');

  mkdirSync(filesDir, { recursive: true });
  writeFileSync(newFilesListPath, '');

  const newFileLines = [];
  for (const relativePath of taskFilePaths(dbPath, taskId)) {
    const sourcePath = join(projectRoot, relativePath);
    if (existsSync(sourcePath)) {
      const destPath = join(filesDir, relativePath);
      mkdirSync(dirname(destPath), { recursive: true });
      copyFileSync(sourcePath, destPath);
    } else {
      newFileLines.push(relativePath);
    }
  }

  if (newFileLines.length > 0) {
    writeFileSync(newFilesListPath, newFileLines.join('\n') + '\n');
  }
}

export function restoreSnapshot({ taskId, crmDir, projectRoot }) {
  const snapshotDir = join(crmDir, 'snapshots', String(taskId));
  const filesDir = join(snapshotDir, 'files');
  const newFilesListPath = join(snapshotDir, 'NEW_FILES.txt');

  if (!existsSync(snapshotDir)) {
    process.stderr.write(`restore: snapshot for task ${taskId} not found, skipping\n`);
    return;
  }

  for (const snapshotFile of listFilesRecursively(filesDir)) {
    const relativePath = relative(filesDir, snapshotFile);
    const destPath = join(projectRoot, relativePath);
    mkdirSync(dirname(destPath), { recursive: true });
    copyFileSync(snapshotFile, destPath);
  }

  if (existsSync(newFilesListPath)) {
    const lines = readFileSync(newFilesListPath, 'utf8').split('\n');
    for (const relativePath of lines) {
      if (relativePath === '') continue;
      const targetPath = join(projectRoot, relativePath);
      if (existsSync(targetPath)) {
        rmSync(targetPath, { force: true });
      }
    }
  }
}
