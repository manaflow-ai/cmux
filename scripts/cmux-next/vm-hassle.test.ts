import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { applyScript, configState, documentedRows, FAULTS, leftoverReport, leftoversOf, linkIdOf, machineToml, PATHS, percentile, requestId, summaryTable } from "./vm-hassle";

describe("vm-hassle", () => {
  test("the documented paths count every step, and the cuts shorten setup and redo only", () => {
    const steps = Object.fromEntries(documentedRows().map((r) => [`${r.flow}/${r.path}`, r.documented_steps]));
    expect(steps).toEqual({
      "setup/before": 8, "redo/before": 8, "cleanup/before": 4, "redo under fault/before": 8, "cleanup after interrupted setup/before": 3,
      "setup/after": 5, "redo/after": 4, "cleanup/after": 4, "redo under fault/after": 4, "cleanup after interrupted setup/after": 3,
    });
    expect(PATHS.after.setup.some((s) => s.command.includes("--wait"))).toBe(true);
    expect(PATHS.after.redo[0].command.startsWith("cmux vm redo NAME")).toBe(true);
  });

  test("a request id is the app's: 13-digit ms and 8 lowercased nonce characters", () => {
    expect(requestId(9_000_000, "ABCDEF01-2345")).toBe("0000009000000-abcdef01");
  });

  test("the machine.toml names one secret and setup that clones and checks tools", () => {
    const t = machineToml("vh-x");
    expect(t).toContain('names = ["HASSLE_SECRET"]');
    expect(t).toContain("git clone");
    expect(t).toContain('HASSLE_TAG = "vh-x"');
  });

  test("the applier's status reads as its state, with the failing step and missing secrets", () => {
    expect(configState("")).toBeNull();
    expect(configState('{"state":"done","secrets":{"missing":[]}}')?.state).toBe("done");
    const failed = configState('noise {"state":"failed","error":"boom","setup":{"failing_index":1},"secrets":{"missing":["A"]}}');
    expect(failed).toEqual({ state: "failed", detail: "failed boom failing_index 1 missing A" });
  });

  test("leftovers are this run's undeleted machines, their snapshots and their previews", () => {
    const ids = new Set(["vm_a", "vm_b"]);
    const out = leftoversOf(
      ids,
      [{ id: "vm_a", status: "deleted" }, { id: "vm_b", status: "running" }, { id: "vm_other", status: "running" }],
      [{ id: "snap_1", machine: "vm_a", status: "ready" }, { id: "snap_2", machine: "vm_other", status: "ready" }, { id: "snap_3", machine: "vm_b", status: "deleting" }],
      [{ machine: "vm_a", port: 8080, links: [{}] }],
    );
    expect(out).toEqual(["machine vm_b (running)", "snapshot snap_1 of vm_a (ready)", "preview vm_a:8080 (1 links)"]);
  });

  test("the table says when a run failed and escapes pipes", () => {
    const md = summaryTable([{ flow: "setup", path: "before", documented_steps: 8, steps: 3, seconds: 12.34, leftovers: [], source: "staging", error: "a|b" }]);
    expect(md).toContain("| setup | before | 8 | 3 | 12.3 | run failed: a\\|b | staging |");
  });

  test("the fault leg's table cell is p50 / max, and the faults break the agent, the disk and the config state", () => {
    expect(percentile([30, 10, 20], 50)).toBe(20);
    expect(percentile([5], 50)).toBe(5);
    const md = summaryTable([{ flow: "redo under fault", path: "after", documented_steps: 4, steps: 4, steps_max: 4, seconds: 80.04, seconds_max: 120.5, runs: 3, leftovers: [], source: "staging" }]);
    expect(md).toContain("| 4 / 4 (p50 / max, 3 runs) | 80.0 / 120.5 |");
    expect(Object.keys(FAULTS)).toEqual(["kill the agent daemon", "fill the disk", "corrupt the machine config state"]);
    expect(FAULTS["kill the agent daemon"]).toContain("kill -9");
  });

  test("each fault checks its own effect and exits non-zero when it did not take", () => {
    expect(FAULTS["kill the agent daemon"]).toContain("kill -9");
    expect(FAULTS["kill the agent daemon"]).toContain("kill -0");
    expect(FAULTS["kill the agent daemon"]).not.toContain("${pid:-none}");
    expect(FAULTS["fill the disk"]).toContain("51200");
    expect(FAULTS["corrupt the machine config state"]).toContain("json.load");
    for (const [name, command] of Object.entries(FAULTS)) {
      const r = spawnSync("bash", ["-n", "-c", command]);
      expect({ name, code: r.status, err: String(r.stderr) }).toEqual({ name, code: 0, err: "" });
      expect(command).toMatch(/exit 1/);
    }
  });

  test("the config apply script parses as shell (no `&;` after the background start)", () => {
    const script = applyScript("1700000000000-0123abcd", "/tmp/vm-hassle-t-1700000000000-0123abcd");
    expect(script).not.toMatch(/&\s*;/);
    const r = spawnSync("bash", ["-n", "-c", script]);
    expect({ code: r.status, err: String(r.stderr) }).toEqual({ code: 0, err: "" });
    expect(spawnSync("bash", ["-n", "-c", script.split("\n").join("; ")]).status).not.toBe(0);
  });

  test("a preview link's id is link.linkId", () => {
    expect(linkIdOf({ link: { linkId: "pl_1", url: "https://x" } })).toBe("pl_1");
    expect(linkIdOf({ link: { id: "pl_1" } })).toBeNull();
    expect(linkIdOf({})).toBeNull();
  });

  test("a failed or malformed list check is reported unknown, never none", () => {
    const ids = new Set(["m1"]);
    expect(leftoverReport(ids, [], { snapshots: [] }, { status: 200, body: { previews: [] } })).toEqual([]);
    const bad = leftoverReport(ids, null, null, { status: 500, body: {} }, ["unknown: cloud.machine.list failed (boom)"]);
    expect(bad).toContain("unknown: cloud.machine.list failed (boom)");
    expect(bad).toContain("unknown: GET /v1/cloud/previews HTTP 500");
    expect(leftoverReport(ids, [], {}, { status: 200, body: {} })).toEqual([
      "unknown: cloud.snapshot.list answered no snapshots list", "unknown: GET /v1/cloud/previews answered no previews list",
    ]);
  });

  test("no step keeps a machine running for its own sake (no soak)", () => {
    const all = Object.values(PATHS).flatMap((p) => Object.values(p).flat());
    expect(all.some((s) => /soak|hours|sleep/i.test(s.command))).toBe(false);
  });
});
