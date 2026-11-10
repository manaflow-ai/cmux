import { describe, expect, test } from "bun:test";
import { configState, documentedRows, leftoversOf, machineToml, PATHS, requestId, summaryTable } from "./vm-hassle";

describe("vm-hassle", () => {
  test("the documented paths count every step, and the cuts shorten setup and redo only", () => {
    const steps = Object.fromEntries(documentedRows().map((r) => [`${r.flow}/${r.path}`, r.documented_steps]));
    expect(steps).toEqual({ "setup/before": 8, "redo/before": 8, "cleanup/before": 4, "setup/after": 5, "redo/after": 4, "cleanup/after": 4 });
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
});
