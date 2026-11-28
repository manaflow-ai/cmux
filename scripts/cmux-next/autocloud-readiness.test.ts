import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

import { INSTANT_TOGGLE_MS, markdown, readiness, text } from "./autocloud-readiness-report.ts";
import { STEPS, gated, verdict, type StepResult } from "./autocloud-sync-verdict.ts";

const pass = (step: StepResult["step"], ms: number | null = null): StepResult => ({ step, status: "pass", ms, detail: "" });
const TIMES: Partial<Record<StepResult["step"], number>> = { toggle_on: 900, tree_visible: 1400, mac_edit_to_vm: 300, vm_edit_to_mac: 250, toggle_off: 1100 };
const green = () => STEPS.map((s) => pass(s, TIMES[s] ?? 10));
const row = (rs: StepResult[], fields: Record<string, unknown> = { env: "staging", machine: "vm_1", resume_ms: 4200 }) =>
  verdict("autocloud-storage-sync-production", rs, fields);
const statuses = (rs: StepResult[]) => readiness(row(rs)).checks.map((c) => c.status);

describe("autocloud readiness", () => {
  test("every probe step passing is three passes, with the numbers", () => {
    const r = readiness(row(green()));
    expect(r.outcome).toBe("pass");
    expect(r.error).toBeUndefined();
    expect(r.checks.map((c) => c.check)).toEqual(["mark", "instant_start", "sync"]);
    expect(r.checks.map((c) => c.status)).toEqual(["pass", "pass", "pass"]);
    expect(r.checks[1].ms).toEqual({ toggle_on_ms: 900, tree_visible_ms: 1400 });
    expect(r.checks[1].detail).toContain("900 ms");
    expect(r.checks[2].ms.vm_edit_to_mac_ms).toBe(250);
    expect(r.setup.ms.machine_resume_ms).toBe(4200);
  });

  test("a slow tree fails instant start and leaves sync measured", () => {
    const rs = green();
    rs[STEPS.indexOf("tree_visible")] = gated("tree_visible", 3600, "seen");
    expect(statuses(rs)).toEqual(["pass", "fail", "pass"]);
    expect(readiness(row(rs)).error).toBe("Instant start: tree_visible: 3600 ms, over the 3000 ms bound; seen");
  });

  test("a slow acknowledgement fails instant start though the probe does not gate it", () => {
    const rs = green();
    rs[STEPS.indexOf("toggle_on")] = pass("toggle_on", INSTANT_TOGGLE_MS + 1);
    const r = readiness(row(rs));
    expect(r.checks.map((c) => c.status)).toEqual(["pass", "fail", "pass"]);
    expect(r.checks[1].detail).toBe(`toggle_on: ${INSTANT_TOGGLE_MS + 1} ms, over the ${INSTANT_TOGGLE_MS} ms bound`);
  });

  test("a failed toggle fails mark and blocks the rest", () => {
    const rs = STEPS.slice(0, STEPS.indexOf("toggle_on")).map((s) => pass(s));
    rs.push({ step: "toggle_on", status: "fail", ms: null, detail: "holder stayed device:d1" });
    const r = readiness(row(rs));
    expect(r.checks.map((c) => c.status)).toEqual(["fail", "blocked", "blocked"]);
    expect(r.error).toBe("Mark: toggle_on: holder stayed device:d1");
    expect(r.checks[1].detail).toBe("did not run: Mark failed");
  });

  test("a setup failure blocks all three and is the reason", () => {
    const rs = [pass("sign_in"), { step: "install", status: "fail", ms: null, detail: "401" } as StepResult];
    const r = readiness(row(rs));
    expect(r.setup).toMatchObject({ status: "fail", detail: "install: 401" });
    expect(r.checks.map((c) => c.status)).toEqual(["blocked", "blocked", "blocked"]);
    expect(r.error).toBe("Mark: did not run: setup (install: 401)");
  });

  test("a driver row with no steps blocks all three with its error", () => {
    const r = readiness({ outcome: "fail", error: "driver: NIGHTLY acpmux fetch: 404" } as never);
    expect(r.outcome).toBe("fail");
    expect(r.setup.detail).toBe("driver: NIGHTLY acpmux fetch: 404");
    expect(r.checks.every((c) => c.status === "blocked")).toBe(true);
  });

  test("a step missing from the row is never a pass", () => {
    const rs = green().filter((s) => s.step !== "both_match");
    expect(statuses(rs)).toEqual(["pass", "pass", "fail"]);
  });

  test("text and markdown carry one line a row", () => {
    const r = readiness(row(green()));
    expect(text(r).trim().split("\n")).toHaveLength(5);
    const md = markdown(r);
    expect(md).toContain("| Instant start | PASS |");
    expect(md).toContain("| Sync | PASS |");
  });

  test("--from reads a probe row and exits 1 on a red", () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "acr-"));
    const rs = green();
    rs[STEPS.indexOf("vm_edit_to_mac")] = gated("vm_edit_to_mac", 2500, "seen");
    writeFileSync(path.join(dir, "row.json"), JSON.stringify(row(rs)));
    const script = path.join(import.meta.dir, "autocloud-readiness.ts");
    const md = path.join(dir, "r.md");
    const p = spawnSync(process.execPath, [script, "--from", path.join(dir, "row.json"), "--markdown", md, "--json", path.join(dir, "r.json")], { encoding: "utf8" });
    expect(p.status).toBe(1);
    expect(p.stdout).toContain("FAIL     Sync");
    expect(readFileSync(md, "utf8")).toContain("| Sync | FAIL | vm_edit_to_mac: 2500 ms");
    expect(JSON.parse(readFileSync(path.join(dir, "r.json"), "utf8")).outcome).toBe("fail");
  });
});
