import { expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { takeLock } from "../src/lock.ts";

// The host spawns long-lived children (the acpmux daemon, detached). The lock's
// descriptor must not leak into them: a child that outlives the host would keep
// the flock, and every later host would be refused.

const holder = join(import.meta.dir, "fakes/lock-holder.ts");

async function firstLine(path: string): Promise<{ line: string; kill: () => void }> {
  const child = Bun.spawn([process.execPath, holder, path], { stdout: "pipe" });
  const reader = child.stdout.getReader();
  let text = "";
  while (!text.includes("\n")) {
    const { value, done } = await reader.read();
    if (done) break;
    text += new TextDecoder().decode(value);
  }
  return { line: text.trim(), kill: () => child.kill() };
}

test("a child spawned while the lock is held does not keep it after release", async () => {
  const dir = mkdtempSync("/tmp/muxx-");
  const path = join(dir, "host.lock");
  const release = takeLock(path);
  expect(release).toBeDefined();
  const sleeper = spawn("/bin/sleep", ["30"], { detached: true, stdio: "ignore" });
  const bunChild = Bun.spawn(["/bin/sleep", "30"]);
  try {
    release?.();
    const next = await firstLine(path);
    next.kill();
    expect(next.line).toBe("held");
  } finally {
    sleeper.kill();
    bunChild.kill();
    rmSync(dir, { recursive: true, force: true });
  }
}, 10_000);
