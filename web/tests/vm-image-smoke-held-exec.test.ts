import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "bun:test";
import { runHeld } from "../scripts/cmux-vm-image/guest";
import type { DetachedExecVm } from "../scripts/cmux-vm-image/detached-exec";
import { runChild } from "./helpers/run-child";

/** A guest that is this machine; `failFrom`/`failTo` make those calls throw the client's TimeoutError. */
function localVm(fail: (n: number) => boolean = () => false): DetachedExecVm & { calls: number; longest: number } {
  const vm = {
    calls: 0,
    longest: 0,
    async exec({ command, env, timeoutMs }: { command: string; env?: Record<string, string>; timeoutMs: number }) {
      const n = ++vm.calls;
      if (fail(n)) throw new DOMException("The operation timed out.", "TimeoutError");
      const t = Date.now();
      const r = await runChild("sh", ["-c", command], { env: { ...process.env, ...env }, timeout: timeoutMs });
      vm.longest = Math.max(vm.longest, Date.now() - t);
      return { statusCode: r.status, stdout: r.stdout, stderr: r.stderr };
    },
  };
  return vm;
}

const roots: string[] = [];
function root(): string {
  const dir = mkdtempSync(join(tmpdir(), "held-"));
  roots.push(dir);
  return dir;
}
afterEach(() => {
  for (const dir of roots.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const poll = { firstPollMs: 20, maxPollMs: 50, graceMs: 2_000, outageMs: 2_000 };

describe("runHeld (smoke daemon holds)", () => {
  test("a hold runs detached: no exec stays open for its length", async () => {
    const vm = localVm();
    const r = await runHeld(vm, "daemon-stays-up", "sleep 1; echo alive=1", 10_000, { root: root(), poll });
    expect(r).toMatchObject({ code: 0, stdout: "alive=1" });
    expect(vm.longest).toBeLessThan(800);
  });

  test("a poll lost to the client's TimeoutError (roll 46106332407) costs one poll, not the smoke", async () => {
    const vm = localVm((n) => n === 3 || n === 4);
    const r = await runHeld(vm, "daemon-stays-up", "sleep 0.5; echo alive=1", 10_000, { root: root(), poll });
    expect(r).toMatchObject({ code: 0, stdout: "alive=1" });
  });

  test("a hold that cannot finish names its check", async () => {
    const vm = localVm((n) => n > 1);
    await expect(runHeld(vm, "daemon-stays-up-after-rebind", "sleep 0.2", 200, { root: root(), poll })).rejects.toThrow(/^daemon-stays-up-after-rebind: /);
  });
});
