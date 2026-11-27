import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "bun:test";
import { DetachedExecLost, detachedExec, type DetachedExecVm } from "../scripts/cmux-vm-image/detached-exec";
import { runChild } from "./helpers/run-child";

/** A guest that is this machine: each exec is one `sh -c`, like the provider's. */
function localVm(hooks: { beforeCall?: (command: string, n: number) => void } = {}): DetachedExecVm & { calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    async exec({ command, env, timeoutMs }) {
      calls.push(command);
      hooks.beforeCall?.(command, calls.length);
      const r = await runChild("sh", ["-c", command], { env: { ...process.env, ...env }, timeout: timeoutMs });
      return { statusCode: r.status, stdout: r.stdout, stderr: r.stderr };
    },
  };
}

const dirs: string[] = [];
function guestDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "detached-exec-"));
  dirs.push(dir);
  return join(dir, "step");
}
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const fast = { firstPollMs: 20, maxPollMs: 50, graceMs: 2_000 };

describe("detachedExec", () => {
  test("returns the command's status, stdout and stderr, run in bash with the start call's env", async () => {
    const vm = localVm();
    const r = await detachedExec(vm, `[[ -n "$STEP_ENV" ]] && echo "out $STEP_ENV" && echo warn >&2`, {
      dir: guestDir(), budgetMs: 10_000, env: { STEP_ENV: "yes" }, ...fast,
    });
    expect(r).toMatchObject({ code: 0, stdout: "out yes", stderr: "warn\n" });
  });

  test("a failing command keeps its own status", async () => {
    const r = await detachedExec(localVm(), "echo partial; exit 7", { dir: guestDir(), budgetMs: 10_000, ...fast });
    expect(r).toMatchObject({ code: 7, stdout: "partial" });
  });

  test("the guest ends a command at its budget with status 124", async () => {
    const r = await detachedExec(localVm(), "sleep 30", { dir: guestDir(), budgetMs: 1_000, ...fast });
    expect(r.code).toBe(124);
  });

  test("no exec stays open for the command's length", async () => {
    const vm = localVm();
    const t0 = Date.now();
    const slowest: number[] = [];
    const timed: DetachedExecVm = {
      async exec(args) {
        const s = Date.now();
        const r = await vm.exec(args);
        slowest.push(Date.now() - s);
        return r;
      },
    };
    const r = await detachedExec(timed, "sleep 1.5; echo done", { dir: guestDir(), budgetMs: 10_000, ...fast });
    expect(r).toMatchObject({ code: 0, stdout: "done" });
    expect(Date.now() - t0).toBeGreaterThanOrEqual(1_500);
    expect(Math.max(...slowest)).toBeLessThan(1_000);
  });

  test("a poll the provider times out (run 45920283687) costs one poll, not the step", async () => {
    const vm = localVm({
      beforeCall: (_command, n) => {
        if (n === 2 || n === 3) throw Object.assign(new Error("The operation timed out."), { name: "TimeoutError" });
      },
    });
    const r = await detachedExec(vm, "sleep 0.3; echo survived", { dir: guestDir(), budgetMs: 10_000, ...fast });
    expect(r).toMatchObject({ code: 0, stdout: "survived" });
  });

  test("a start whose answer was lost is read back, not run twice", async () => {
    const dir = guestDir();
    let lost = false;
    const inner = localVm();
    const vm: DetachedExecVm = {
      async exec(args) {
        const r = await inner.exec(args);
        if (!lost) {
          lost = true;
          throw Object.assign(new Error("The operation timed out."), { name: "TimeoutError" });
        }
        return r;
      },
    };
    const r = await detachedExec(vm, `echo run >> ${dir}.count; echo ok`, { dir, budgetMs: 10_000, ...fast });
    expect(r).toMatchObject({ code: 0, stdout: "ok" });
    expect(readFileSync(`${dir}.count`, "utf8").trim().split("\n")).toEqual(["run"]);
  });

  test("polls that fail past the deadline throw with the provider's error named", async () => {
    let n = 0;
    const inner = localVm();
    const vm: DetachedExecVm = {
      async exec(args) {
        if (++n > 1) throw Object.assign(new Error("The operation timed out."), { name: "TimeoutError" });
        return inner.exec(args);
      },
    };
    const error = await detachedExec(vm, "sleep 5", { dir: guestDir(), budgetMs: 100, ...fast, graceMs: 200 }).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(DetachedExecLost);
    expect(String((error as Error).message)).toContain("last poll failed: TimeoutError");
  });
});
