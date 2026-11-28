import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { runChild } from "./helpers/run-child";
import { guestShellProblems } from "../scripts/cmux-vm-image/shell-check";
import { IO_PROBE_COMMAND, IO_PROBE_LIMIT, StepLog } from "../scripts/cmux-vm-image/guest";

type FakeVm = Parameters<StepLog["step"]>[0];

/** A guest whose step commands answer `answer`; the probe answers a fixed line. */
function fakeVm(answer: { statusCode: number; delayMs?: number }, probes: string[]): FakeVm {
  return {
    exec: async ({ command }: { command: string }) => {
      if (command.includes("psi_io")) {
        probes.push(command);
        return { statusCode: 0, stdout: "psi_io some avg10=91.00\ndd_direct_32M_ms 4200 /opt/x\n", stderr: "" };
      }
      if (answer.delayMs) await new Promise((r) => setTimeout(r, answer.delayMs));
      return { statusCode: answer.statusCode, stdout: "", stderr: "" };
    },
  } as unknown as FakeVm;
}

describe("a bake step that fails or runs slow logs the guest's disk and CPU (rolls 46107492079, 46100096471)", () => {
  test("the probe parses under the guest's /bin/sh", async () => {
    expect(guestShellProblems(IO_PROBE_COMMAND)).toEqual({ refused: [], suspect: [] });
    // dash runs it here too, on any Linux runner, and prints its lines whatever the machine has.
    const { stdout: out } = await runChild("sh", ["-c", IO_PROBE_COMMAND], { timeout: 40_000 });
    expect(out).toContain("psi_io");
    expect(out).toMatch(/dd_direct/);
  });

  test("a failed step logs IO_PROBE and still fails the same way", async () => {
    const log = path.join(mkdtempSync(path.join(tmpdir(), "io-probe-")), "bake.log");
    const L = new StepLog(log);
    const probes: string[] = [];
    await expect(L.step(fakeVm({ statusCode: 124 }, probes), "clean", "true")).rejects.toThrow("step clean failed");
    expect(probes.length).toBe(1);
    expect(readFileSync(log, "utf8")).toContain("IO_PROBE [clean] after status=124");
  });

  test("a fast passing step runs no probe", async () => {
    const L = new StepLog(path.join(mkdtempSync(path.join(tmpdir(), "io-probe-")), "bake.log"));
    const probes: string[] = [];
    await L.step(fakeVm({ statusCode: 0 }, probes), "host-dirs", "true");
    expect(probes.length).toBe(0);
  });

  test("probes stop at the limit", async () => {
    const L = new StepLog(path.join(mkdtempSync(path.join(tmpdir(), "io-probe-")), "bake.log"));
    const probes: string[] = [];
    const vm = fakeVm({ statusCode: 0 }, probes);
    for (let i = 0; i < IO_PROBE_LIMIT + 3; i++) await L.logIoProbe(vm, `s${i}`, "test");
    expect(probes.length).toBe(IO_PROBE_LIMIT);
  });
});
