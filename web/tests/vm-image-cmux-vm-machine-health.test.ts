import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { MACHINE_HEALTH_ARM_COMMAND, machineHealthBakeCommand, machineHealthFiles, machineHealthSmokeCommand, machineHealthSmokeProblems, MACHINE_HEALTH_SCRIPT } from "../scripts/cmux-vm-image/machine-health";
import { runChild } from "./helpers/run-child";

const MEM = 4_101_844_992;
const healthy = (over: Record<string, string> = {}) =>
  Object.entries({
    timer: "active",
    timerpass: "success",
    run: "0",
    result: "success",
    health: '{"schema": 1, "checkedAt": "2026-10-25T21:00:00Z", "problems": [], "fixed": []}',
    scope: `8192 ${Math.floor(MEM * 0.7)} ${Math.floor(MEM * 0.8)} 0`,
    userslice: String(Math.floor(MEM * 0.9)),
    memtotal: String(MEM),
    usermanager: "OOMScoreAdjust=-900 MemoryMin=67108864",
    userservice: "200",
    ...over,
  })
    .map(([k, v]) => `${k}=${v}`)
    .join("\n");

describe("cmux-machine-health in the cmux VM image", () => {
  test("the script's unit tests pass (fake host: DNS, disk, RAM, acpmux, peers, install)", async () => {
    const result = await runChild("python3", ["-m", "unittest", "-v", "test_cmux_machine_health"], { cwd: path.dirname(MACHINE_HEALTH_SCRIPT), env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" }, timeout: 60_000 });
    expect({ status: result.status, tail: result.stderr.trim().split("\n").at(-1) }).toEqual({ status: 0, tail: "OK" });
  }, 70_000);

  test("the bake installs through the script's own install and the smoke commands parse", async () => {
    // The timer is enabled but not started for the rest of the bake; it starts as the last step before the snapshot.
    expect(machineHealthBakeCommand()).toStartWith("python3 /root/cmux-machine-health install --no-start && rm -f /root/cmux-machine-health && ");
    expect(machineHealthBakeCommand()).not.toContain("systemctl start cmux-machine-health.timer");
    expect(machineHealthBakeCommand()).toContain("cmux-machine-health run --check-only");
    expect(machineHealthBakeCommand()).not.toContain("systemctl start cmux-machine-health.service");
    expect(MACHINE_HEALTH_ARM_COMMAND).toContain("systemctl start cmux-machine-health.timer");
    const bake = readFileSync(new URL("../scripts/cmux-vm-image/bake.ts", import.meta.url), "utf8");
    const arm = bake.indexOf('"machine-health-arm"');
    expect(arm).toBeGreaterThan(bake.indexOf('"drop-cache-warm-bind-path"'));
    expect(bake.slice(arm, bake.indexOf("async function", arm))).not.toContain("L.step(");
    expect(machineHealthFiles().map((f) => f.path)).toEqual(["/root/cmux-machine-health", "/usr/local/bin/cmux-machine-hygiene"]);
    for (const command of [machineHealthBakeCommand(), MACHINE_HEALTH_ARM_COMMAND, machineHealthSmokeCommand("cmux")]) {
      expect((await runChild("bash", ["-n"], { input: command })).status).toBe(0);
    }
  });

  test("a healthy clone has no smoke problems", () => {
    expect(machineHealthSmokeProblems(healthy())).toEqual([]);
  });

  test("each broken piece is named", () => {
    expect(machineHealthSmokeProblems(healthy({ timer: "inactive" }))).toEqual(["timer: inactive"]);
    expect(machineHealthSmokeProblems(healthy({ timerpass: "" }))).toEqual(["timer: no pass started by the timer within 90 s (no health file)"]);
    expect(machineHealthSmokeProblems(healthy({ run: "1", result: "timeout" }))).toEqual(["one pass: exit 1, result timeout"]);
    expect(machineHealthSmokeProblems(healthy({ health: "{" }))).toEqual(["health file: not JSON: {"]);
    expect(machineHealthSmokeProblems(healthy({ health: '{"schema": 1, "checkedAt": "2026-10-25T21:00:00Z", "problems": [{"check": "dns"}], "fixed": []}' }))).toEqual(['health file problems: [{"check":"dns"}]']);
    expect(machineHealthSmokeProblems(healthy({ scope: "max max max max" }))[0]).toStartWith("session scope limits: pids.max max");
    expect(machineHealthSmokeProblems(healthy({ scope: `8192 ${Math.floor(MEM * 0.7)} ${Math.floor(MEM * 0.8)} max` }))[0]).toContain("memory.swap.max max");
    expect(machineHealthSmokeProblems(healthy({ userslice: "infinity" }))).toEqual([`user.slice MemoryMax: infinity of ${MEM} (want 90%)`]);
    expect(machineHealthSmokeProblems(healthy({ usermanager: "OOMScoreAdjust=100 MemoryMin=0" }))).toEqual(["user manager: OOMScoreAdjust=100 MemoryMin=0"]);
    expect(machineHealthSmokeProblems(healthy({ userservice: "-900" }))).toEqual(["user service OOM score: -900 (want 200, not the manager's -900)"]);
  });
});
