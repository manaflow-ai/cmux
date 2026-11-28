import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

import { STEPS, clockOffset, crossClockMs, gated, parseWatch, TREE_HASH_SH, verdict, type StepResult } from "./autocloud-sync-verdict.ts";
import { watcher } from "./autocloud-sync-probe.ts";

const pass = (step: StepResult["step"], ms: number | null = null): StepResult => ({ step, status: "pass", ms, detail: "" });

describe("autocloud sync verdict", () => {
  test("every step passing is ok, with the tree's time as ms", () => {
    const rs = STEPS.map((s) => pass(s, s === "tree_visible" ? 1200 : s === "mac_edit_to_vm" ? 300 : null));
    const row = verdict("p", rs, { machine: "vm_1" });
    expect(row.outcome).toBe("ok");
    expect(row.error).toBeUndefined();
    expect(row.ms).toBe(1200);
    expect(row.mac_edit_to_vm_ms).toBe(300);
    expect(row.machine).toBe("vm_1");
  });

  test("red names the first failing step, and later timings ride along", () => {
    const rs = STEPS.map((s) => pass(s, 100));
    rs[STEPS.indexOf("mac_edit_to_vm")] = gated("mac_edit_to_vm", 2600, "seen");
    rs[STEPS.indexOf("toggle_off")] = { step: "toggle_off", status: "fail", ms: null, detail: "stuck" };
    const row = verdict("p", rs, {});
    expect(row.outcome).toBe("fail");
    expect(row.error).toBe("mac_edit_to_vm: 2600 ms, over the 2000 ms bound; seen");
    expect(row.vm_edit_to_mac_ms).toBe(100);
    expect(row.mac_edit_to_vm_ms).toBe(2600);
  });

  test("a step that never ran is a skip and fails the row", () => {
    const row = verdict("p", [pass("sign_in")], {});
    expect(row.outcome).toBe("fail");
    expect(row.error).toBe("install: did not run");
    expect(row.steps).toHaveLength(STEPS.length);
  });

  test("gates: at the bound passes, over it fails, unmeasured fails", () => {
    expect(gated("tree_visible", 3000, "").status).toBe("pass");
    expect(gated("tree_visible", 3001, "").status).toBe("fail");
    expect(gated("vm_edit_to_mac", null, "gone").detail).toBe("gone");
  });

  test("clock offset takes the shortest round trip's midpoint", () => {
    const c = clockOffset([{ before: 0, vm: 5000, after: 400 }, { before: 1000, vm: 6050, after: 1100 }]);
    expect(c).toEqual({ offsetMs: 5000, rttMs: 100 });
    expect(crossClockMs(2000, 7300, 5000)).toBe(300);
    expect(crossClockMs(2000, 6900, 5000)).toBe(0);
  });

  test("watch output", () => {
    expect(parseWatch("@@start 1000000000\n@@seen 3000000000\n")).toMatchObject({ startMs: 1000, seenMs: 3000, firstPoll: false });
    expect(parseWatch("@@start 1\n@@seen 2000000 first\n").firstPoll).toBe(true);
    expect(parseWatch("@@start 1\n@@timeout ls: no such\n").detail).toContain("no such");
  });

  test("the watcher and the tree hash run in sh", () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "asp-"));
    mkdirSync(path.join(dir, "tree"), { recursive: true });
    writeFileSync(path.join(dir, "tree", "a.txt"), "a\n");
    writeFileSync(path.join(dir, "tree", "b c.txt"), "b\n");
    writeFileSync(path.join(dir, "tree", ".marker"), "m\n");
    const h = spawnSync("sh", ["-c", TREE_HASH_SH(`'${dir}/tree'`)]).stdout.toString().trim();
    expect(h).toMatch(/^[0-9a-f]{64}$/);
    expect(h).not.toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".slice(0, 64));
    writeFileSync(path.join(dir, "tree", ".marker"), "changed\n");
    expect(spawnSync("sh", ["-c", TREE_HASH_SH(`'${dir}/tree'`)]).stdout.toString().trim()).not.toBe(h);
    writeFileSync(path.join(dir, "tree", ".marker"), "m\n");
    const out = spawnSync("sh", ["-c", watcher(`[ "$(${TREE_HASH_SH(`'${dir}/tree'`)})" = "${h}" ]`, 2)], { env: { ...process.env, HOME: dir } }).stdout.toString();
    expect(parseWatch(out)).toMatchObject({ firstPoll: true });
    const miss = spawnSync("sh", ["-c", watcher(`[ -f '${dir}/nope' ]`, 1, `ls '${dir}/nope'`)], { env: { ...process.env, HOME: dir } }).stdout.toString();
    expect(parseWatch(miss).seenMs).toBeNull();
    expect(parseWatch(miss).detail).toContain("No such file");
  });
});
