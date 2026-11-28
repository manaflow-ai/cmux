import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { runChild } from "./helpers/run-child";
import { guestShellProblems } from "../scripts/cmux-vm-image/shell-check";
import { HANG_SNAPSHOT_COMMAND, HANG_SNAPSHOT_LIMIT, StepLog, recordedStepCommand } from "../scripts/cmux-vm-image/guest";

type FakeVm = Parameters<StepLog["step"]>[0];

/** A guest whose step commands answer `step`; the IO probe and the hang snapshot answer fixed lines. */
function fakeVm(step: () => Promise<{ statusCode: number }>, snapshots: string[]): FakeVm {
  return {
    exec: async ({ command }: { command: string }) => {
      if (command.includes("fuse_mounts")) {
        snapshots.push(command);
        return { statusCode: 0, stdout: "fuse_mounts fuse.cmux:/w\nps 42 1 S request_wait_answer 05:01 sync\n", stderr: "" };
      }
      if (command.includes("psi_io")) return { statusCode: 0, stdout: "vmstat r=0 b=0 wa=0\n", stderr: "" };
      return { ...(await step()), stdout: "", stderr: "" };
    },
  } as unknown as FakeVm;
}

const newLog = () => path.join(mkdtempSync(path.join(tmpdir(), "hang-snapshot-")), "bake.log");

describe("a bake step that hangs logs what the guest is stuck on (rolls 46107492079, 46114210062)", () => {
  test("the snapshot parses under the guest's /bin/sh and prints its lines here", async () => {
    expect(guestShellProblems(HANG_SNAPSHOT_COMMAND).refused).toEqual([]);
    const { stdout: out } = await runChild("sh", ["-c", HANG_SNAPSHOT_COMMAND], { timeout: 30_000 });
    expect(out).toContain("fuse_mounts");
    expect(out).toContain("fuse_waiting");
    expect(out).toMatch(/^mem /m);
    expect(out).toMatch(/^ps +\d+ +\d+ /m);
  });

  test("status 124 logs HANG_SNAPSHOT and still fails the same way", async () => {
    const log = newLog();
    const snapshots: string[] = [];
    const L = new StepLog(log);
    await expect(L.step(fakeVm(async () => ({ statusCode: 124 }), snapshots), "drop-cache-warm-bind-path", "true")).rejects.toThrow("step drop-cache-warm-bind-path failed");
    expect(snapshots.length).toBe(1);
    expect(readFileSync(log, "utf8")).toContain("HANG_SNAPSHOT [drop-cache-warm-bind-path] after status=124");
    expect(readFileSync(log, "utf8")).toContain("request_wait_answer");
  });

  test("the client's TimeoutError logs HANG_SNAPSHOT and is rethrown as is", async () => {
    const log = newLog();
    const snapshots: string[] = [];
    const L = new StepLog(log);
    L.recoverWaitsMs = [];
    const timeout = Object.assign(new Error("The operation timed out."), { name: "TimeoutError" });
    await expect(L.step(fakeVm(async () => { throw timeout; }, snapshots), "clean", "true")).rejects.toBe(timeout);
    expect(snapshots.length).toBe(1);
    expect(readFileSync(log, "utf8")).toContain("HANG_SNAPSHOT [clean] after the client's TimeoutError");
  });

  test("an ordinary failure takes no snapshot", async () => {
    const snapshots: string[] = [];
    const L = new StepLog(newLog());
    await expect(L.step(fakeVm(async () => ({ statusCode: 1 }), snapshots), "x", "true")).rejects.toThrow("step x failed");
    expect(snapshots.length).toBe(0);
  });

  test("snapshots stop at the limit", async () => {
    const snapshots: string[] = [];
    const L = new StepLog(newLog());
    const vm = fakeVm(async () => ({ statusCode: 0 }), snapshots);
    for (let i = 0; i < HANG_SNAPSHOT_LIMIT + 3; i++) await L.logHangSnapshot(vm, `s${i}`, "test");
    expect(snapshots.length).toBe(HANG_SNAPSHOT_LIMIT);
  });
});

/**
 * A guest that runs each command in a real /bin/sh, under a fake root for the step's result dir, and loses the
 * exec's answer of the first step (statusCode undefined, as roll 46181977393's drop-cache-warm-bind-path at the
 * 300 s cap) or throws the client's TimeoutError, after the command ran.
 */
function shellVm(root: string, lose: "status" | "timeout" | "none", snapshots: string[] = []): FakeVm {
  let lost = false;
  return {
    exec: async ({ command }: { command: string }) => {
      if (command.includes("fuse_mounts")) {
        snapshots.push(command);
        return { statusCode: 0, stdout: "fuse_mounts \n", stderr: "" };
      }
      if (command.includes("psi_io")) return { statusCode: 0, stdout: "vmstat r=0 b=0 wa=0\n", stderr: "" };
      const r = await runChild("sh", ["-c", command.replaceAll("/root/.cmux-step", root)], { timeout: 30_000 });
      if (!lost && lose !== "none" && command.includes("> ")) {
        lost = true;
        if (lose === "timeout") throw Object.assign(new Error("The operation timed out."), { name: "TimeoutError" });
        return { statusCode: undefined, stdout: "", stderr: "" };
      }
      return { statusCode: r.status ?? 137, stdout: r.stdout, stderr: r.stderr };
    },
  } as unknown as FakeVm;
}

describe("a step whose exec answer is lost reads its result back from the guest (roll 46181977393)", () => {
  const root = () => mkdtempSync(path.join(tmpdir(), "step-root-"));

  test("the recorded command parses under the guest's /bin/sh, keeps the output and status, and an exit still records", async () => {
    const wrapped = recordedStepCommand("/tmp/x/s-1", "echo out && echo err >&2 && exit 3 # trailing comment");
    expect(guestShellProblems(wrapped).refused).toEqual([]);
    const dir = path.join(root(), "s-1");
    const r = await runChild("sh", ["-c", recordedStepCommand(dir, "echo out && echo err >&2 && exit 3 # trailing comment")]);
    expect(r.stdout).toBe("out\n");
    expect(r.stderr).toBe("err\n");
    expect(readFileSync(path.join(dir, "status"), "utf8").trim()).toBe("3");
  });

  test("status lost at the cap after the guest finished: ok, with its output, and no hang snapshot", async () => {
    const log = newLog();
    const snapshots: string[] = [];
    const L = new StepLog(log);
    const out = await L.step(shellVm(root(), "status", snapshots), "drop-cache-warm-bind-path", "echo warmed && free -m >/dev/null 2>&1; true");
    expect(out).toBe("warmed\n");
    expect(snapshots.length).toBe(0);
    const text = readFileSync(log, "utf8");
    expect(text).toContain("RECOVERED [drop-cache-warm-bind-path] after status=124: the guest recorded status=0");
    expect(text).toContain("ok [drop-cache-warm-bind-path]");
  });

  test("the client's TimeoutError after the guest finished: the recorded failure fails the step as itself", async () => {
    const L = new StepLog(newLog());
    await expect(L.step(shellVm(root(), "timeout"), "clean", "echo nope >&2; exit 2")).rejects.toThrow("step clean failed");
  });

  test("an answered exec is unchanged", async () => {
    const L = new StepLog(newLog());
    expect(await L.step(shellVm(root(), "none"), "x", "printf 'a\\nb\\n'")).toBe("a\nb\n");
  });
});
