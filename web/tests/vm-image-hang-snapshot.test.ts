import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { runChild } from "./helpers/run-child";
import { guestShellProblems } from "../scripts/cmux-vm-image/shell-check";
import { HANG_SNAPSHOT_COMMAND, HANG_SNAPSHOT_LIMIT, StepLog } from "../scripts/cmux-vm-image/guest";

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
