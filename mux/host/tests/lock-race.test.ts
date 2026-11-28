import { afterEach, beforeAll, describe, expect, mock, test } from "bun:test";
import * as fsModule from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Two hosts racing for the MUX_HOME lock must never both win. The races need
// one taker to run in the middle of another, so node:fs is wrapped: a hook runs
// the second taker at the exact point where the first one is exposed. With no
// hook set, every call passes through unchanged.

// Copies taken before the mock: bun updates live bindings of a mocked module in place.
const realFs = { ...fsModule };
const { mkdtempSync, rmSync, utimesSync, writeFileSync: realWriteFile } = realFs;

type Fn = "readFileSync" | "writeSync" | "writeFileSync" | "rmSync" | "fstatSync";
/** `path`: fire only for a call on this path. */
type Hook = { fns: Fn[]; path?: string; run: () => void } | undefined;
let hook: Hook;

function fire(fn: Fn, path?: unknown): void {
  if (!hook?.fns.includes(fn)) return;
  if (hook.path !== undefined && hook.path !== path) return;
  const { run } = hook;
  hook = undefined; // once
  run();
}

mock.module("node:fs", () => ({
  ...realFs,
  readFileSync: (...args: Parameters<typeof realFs.readFileSync>) => {
    const value = realFs.readFileSync(...args);
    fire("readFileSync");
    return value;
  },
  writeSync: (...args: Parameters<typeof realFs.writeSync>) => {
    fire("writeSync");
    return (realFs.writeSync as (...a: unknown[]) => number)(...args);
  },
  writeFileSync: (...args: Parameters<typeof realFs.writeFileSync>) => {
    realFs.writeFileSync(...args);
    fire("writeFileSync");
  },
  fstatSync: (...args: Parameters<typeof realFs.fstatSync>) => {
    fire("fstatSync");
    return realFs.fstatSync(...args);
  },
  rmSync: (...args: Parameters<typeof realFs.rmSync>) => {
    fire("rmSync", args[0]);
    realFs.rmSync(...args);
  },
}));

let takeLock: (path: string) => (() => void) | undefined;
let lockHolder: (path: string) => number | undefined;
beforeAll(async () => {
  ({ takeLock, lockHolder } = await import("../src/lock.ts"));
});

const dirs: string[] = [];
afterEach(() => {
  hook = undefined;
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function lockPath(): string {
  const dir = mkdtempSync(join(tmpdir(), "mux-lock-"));
  dirs.push(dir);
  return join(dir, "host.lock");
}

/** A pid that no process has (above every default pid_max). */
const DEAD_PID = 99_999_999;

describe("MUX_HOME lock races", () => {
  test("two takers of a stale lock: only one wins", () => {
    const path = lockPath();
    realWriteFile(path, String(DEAD_PID));
    let first: (() => void) | undefined;
    let fired = false;
    // The second taker reads the dead pid; before it acts on it, the first
    // taker runs to the end (it takes the stale lock over and holds it).
    hook = { fns: ["readFileSync"], run: () => ((fired = true), (first = takeLock(path))) };
    const second = takeLock(path);
    // A lock that never reads the old owner has no such window: the first taker comes after.
    if (!fired) first = takeLock(path);
    expect([first, second].filter(Boolean).length).toBe(1);
    expect(Number(String(realFs.readFileSync(path, "utf8")).split("\n")[0])).toBe(process.pid);
  });

  test("a taker that stalls inside a stale takeover does not remove the next holder's lock", () => {
    const path = lockPath();
    realWriteFile(path, String(DEAD_PID));
    let second: (() => void) | undefined;
    let fired = false;
    // The first taker is about to remove the stale lock and stalls for longer
    // than any orphan limit (its takeover marker looks old); meanwhile a second
    // taker arrives and takes the lock.
    hook = {
      fns: ["rmSync"],
      path,
      run: () => {
        fired = true;
        const old = new Date(Date.now() - 60_000);
        try {
          utimesSync(`${path}.takeover`, old, old);
        } catch {
          // No takeover marker in this lock design.
        }
        second = takeLock(path);
      },
    };
    const first = takeLock(path);
    if (!fired) second = takeLock(path);
    expect([first, second].filter(Boolean).length).toBe(1);
  });

  test("a taker that runs while the lock file is being written does not take it", () => {
    const path = lockPath();
    let second: (() => void) | undefined;
    // The second taker runs after the first one created the lock and before
    // its pid is in it (or, with an atomic write, before it is in place).
    hook = { fns: ["writeSync", "writeFileSync"], run: () => (second = takeLock(path)) };
    const first = takeLock(path);
    const winners = [first, second].filter(Boolean).length;
    expect(winners).toBe(1);
    expect(Number(String(realFs.readFileSync(path, "utf8")).split("\n")[0])).toBe(process.pid);
  });

  test("an upgrade check that throws refuses and leaves the flock free", () => {
    const path = lockPath();
    const older = Bun.spawn(["/bin/sleep", "30"]);
    try {
      // Pid-only text naming a live process: the upgrade check stats the file, and that throws.
      realWriteFile(path, String(older.pid));
      hook = { fns: ["fstatSync"], run: () => { throw new Error("stat failed"); } };
      expect(takeLock(path)).toBeUndefined();
      expect(lockHolder(path)).toBeUndefined();
    } finally {
      older.kill();
    }
  });
});
