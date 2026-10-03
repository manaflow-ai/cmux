import { afterEach, describe, expect, test } from "bun:test";
import { type ChildProcess, spawn } from "node:child_process";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { lockHolder, takeLock } from "../src/lock.ts";

// The lock is a kernel lock held by a live process. A crashed holder leaves no
// stale lock, and the pid text in the file never decides anything, so a reused
// pid or a slow runtime start cannot steal or block the lock.

const cleanups: Array<() => void> = [];
afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

function lockPath(): string {
  const dir = mkdtempSync(join(tmpdir(), "mux-lock-reuse-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  return join(dir, "host.lock");
}

function track(child: ChildProcess): ChildProcess {
  cleanups.push(() => child.kill("SIGKILL"));
  return child;
}

/** A second process that takes the lock; resolves with its first output line. */
async function holder(path: string): Promise<{ child: ChildProcess; line: string }> {
  const child = track(spawn(process.execPath, [join(import.meta.dir, "fakes", "lock-holder.ts"), path], { stdio: ["ignore", "pipe", "inherit"] }));
  const line = await new Promise<string>((resolve, reject) => {
    let text = "";
    child.stdout?.on("data", (chunk) => {
      text += String(chunk);
      if (text.includes("\n")) resolve(text.split("\n")[0] ?? "");
    });
    child.on("exit", (code) => reject(new Error(`lock holder exited ${code}`)));
  });
  return { child, line };
}

describe("MUX_HOME lock held by another process", () => {
  test("a lock held by a live process is refused, and is free once that process dies", async () => {
    const path = lockPath();
    const { child, line } = await holder(path);
    expect(line).toBe("held");
    expect(takeLock(path)).toBeUndefined();
    expect(lockHolder(path)).toBe(child.pid);
    const exited = new Promise((resolve) => child.once("exit", resolve));
    child.kill("SIGKILL");
    await exited;
    const release = takeLock(path);
    expect(release).toBeDefined();
    release?.();
  });

  test("a lock file that names a live process which does not hold the lock is free (pid reuse)", () => {
    const path = lockPath();
    const other = track(spawn("sleep", ["30"], { stdio: "ignore" }));
    writeFileSync(path, `${other.pid}\n0\n`);
    const release = takeLock(path);
    expect(release).toBeDefined();
    release?.();
  });

  test("a second taker in another process is refused while this process holds the lock", async () => {
    const path = lockPath();
    const release = takeLock(path);
    expect(release).toBeDefined();
    const { line } = await holder(path);
    expect(line).toBe("refused");
    release?.();
  });

});

/** The OS start time of a process, epoch ms (ps truncates to seconds). */
function startMs(pid: number): number {
  const text = spawnSync("ps", ["-o", "lstart=", "-p", String(pid)], { env: { ...process.env, LC_ALL: "C", TZ: "UTC" } })
    .stdout.toString()
    .trim()
    .replace(/\s+/g, " ");
  return Date.parse(`${text} UTC`);
}

// Upgrade check (remove after one release): an older host holds the lock by
// its file text only, with no kernel lock. A new host must not start beside it.
describe("MUX_HOME lock written by an older host", () => {
  test("an old lock (pid and start) of a live older host refuses the start", () => {
    const path = lockPath();
    const old = track(spawn("sleep", ["30"], { stdio: "ignore" }));
    const pid = old.pid ?? 0;
    writeFileSync(path, `${pid}\n${startMs(pid) + 500}\n`);
    expect(takeLock(path)).toBeUndefined();
  });

  test("an old pid-only lock of a live older host refuses the start", () => {
    const path = lockPath();
    const old = track(spawn("sleep", ["30"], { stdio: "ignore" }));
    writeFileSync(path, String(old.pid));
    expect(takeLock(path)).toBeUndefined();
  });

  test("an old pid-only lock whose pid was reused after the file was written is free", () => {
    const path = lockPath();
    const reused = track(spawn("sleep", ["30"], { stdio: "ignore" }));
    writeFileSync(path, String(reused.pid));
    const old = new Date(Date.now() - 60_000);
    utimesSync(path, old, old);
    const release = takeLock(path);
    expect(release).toBeDefined();
    release?.();
  });
});
