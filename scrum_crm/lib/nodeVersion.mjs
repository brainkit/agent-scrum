// Version gate for node:sqlite (stable since Node 22.5, no dependencies —
// this module must stay import-safe on any Node version, including ones
// that predate node:sqlite, so crm.mjs can check it before touching db.mjs.
export const MIN_NODE_MAJOR = 22;
export const MIN_NODE_MINOR = 5;

export function checkNodeVersion(versionString) {
  const [major, minor] = versionString.split('.').map(Number);
  if (major > MIN_NODE_MAJOR) {
    return true;
  }
  return major === MIN_NODE_MAJOR && minor >= MIN_NODE_MINOR;
}

export function formatNodeVersionError(versionString) {
  return `agent-scrum requires Node.js >= ${MIN_NODE_MAJOR}.${MIN_NODE_MINOR} (node:sqlite); found v${versionString}`;
}
