import { afterEach, describe, expect, test } from "bun:test";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { takeLock } from "../src/lock.ts";

// A crashed host leaves its lock behind. If the OS later gives that pid to an
// unrelated process, the lock must still count as stale: the lock records the
// owner's start time as well as its pid.

const cleanups: Array<() => void> = [];
afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

function lockPath(): string {
  const dir = mkdtempSync(join(tmpdir(), "mux-lock-reuse-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  return join(dir, "host.lock");
}

/** A live process that is not a mux host. */
function bystander(): ChildProcess {
  const child = spawn("sleep", ["30"], { stdio: "ignore" });
  cleanups.push(() => child.kill("SIGKILL"));
  return child;
}

/** The OS start time of a process, epoch ms. */
function startMs(pid: number): number {
  const text = spawnSync("ps", ["-o", "lstart=", "-p", String(pid)], { env: { ...process.env, LC_ALL: "C", TZ: "UTC" } })
    .stdout.toString()
    .trim()
    .replace(/\s+/g, " ");
  return Date.parse(`${text} UTC`);
}

describe("MUX_HOME lock and pid reuse", () => {
  test("a lock whose pid now belongs to another process is stale", () => {
    const path = lockPath();
    const other = bystander();
    // The crashed owner had this pid but started at another time.
    writeFileSync(path, `${other.pid}\n0\n`);
    const release = takeLock(path);
    expect(release).toBeDefined();
    expect(Number(readFileSync(path, "utf8").split("\n")[0])).toBe(process.pid);
    release?.();
  });

  test("a lock whose pid and start time match a live process is held", () => {
    const path = lockPath();
    const other = bystander();
    const pid = other.pid ?? 0;
    writeFileSync(path, `${pid}\n${startMs(pid)}\n`);
    expect(takeLock(path)).toBeUndefined();
  });
});
