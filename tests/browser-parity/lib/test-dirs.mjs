// Temporary directories for tests. A test removes only a directory it made
// here, in this process: removeTestDir refuses anything else, and anything
// that is (or is above) the system temporary directory, /tmp, the home
// directory or the working directory, so a cleanup can never take files it
// did not create.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const made = new Set();

const real = (p) => {
  try {
    return fs.realpathSync(p);
  } catch {
    return path.resolve(p);
  }
};

const tmpRoot = () => real(os.tmpdir());

function protectedPaths() {
  return [os.tmpdir(), process.env.TMPDIR, "/tmp", "/private/tmp", "/var/tmp", os.homedir(), process.cwd(), "/"]
    .filter(Boolean)
    .map(real);
}

/// Makes a new directory `<parent>/<prefix>XXXXXX` (mkdtemp) under the
/// system temporary directory and records it as this process's own.
export function makeTestDir(prefix, { parent = os.tmpdir(), mode } = {}) {
  const under = (p, root) => p === root || p.startsWith(root + path.sep);
  const asked = path.resolve(parent);
  if (!under(asked, path.resolve(os.tmpdir())) && !under(asked, tmpRoot())) {
    throw new Error(`makeTestDir: ${parent} is not under the system temporary directory`);
  }
  fs.mkdirSync(asked, { recursive: true });
  const base = real(asked);
  if (!under(base, tmpRoot())) throw new Error(`makeTestDir: ${parent} is not under the system temporary directory`);
  const dir = real(fs.mkdtempSync(path.join(base, prefix)));
  if (mode !== undefined) fs.chmodSync(dir, mode);
  made.add(dir);
  return dir;
}

/// Removes, recursively, a directory makeTestDir made in this process.
export function removeTestDir(dir) {
  const target = real(dir);
  if (!made.has(target)) throw new Error(`removeTestDir: refusing to remove ${dir}: this process did not make it with makeTestDir`);
  const root = tmpRoot();
  if (!target.startsWith(root + path.sep)) throw new Error(`removeTestDir: refusing to remove ${dir}: not under ${root}`);
  for (const p of protectedPaths()) {
    if (target === p || p.startsWith(target + path.sep)) throw new Error(`removeTestDir: refusing to remove ${dir}: it is or holds ${p}`);
  }
  fs.rmSync(target, { recursive: true, force: true });
  made.delete(target);
}

/// Removes a directory makeTestDir made only when it is empty, as the app
/// removes a session's temporary directory at close.
export function removeTestDirIfEmpty(dir) {
  const target = real(dir);
  if (!made.has(target)) return;
  try {
    fs.rmdirSync(target);
    made.delete(target);
  } catch {}
}
