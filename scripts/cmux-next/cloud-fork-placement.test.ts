import { describe, expect, test } from "bun:test";
import { armSummary, facts, p95, parity, parityCommand, setupCommand, verdict, type RunRow } from "./cloud-fork-placement.ts";

const row = (over: Partial<RunRow>): RunRow => ({
  run: 1, parent: "vm_p", child: "vm_c", parent_ready_ms: 1, fork_call_ms: 6000, fork_status: 200,
  fork_to_first_exec_ms: 7000, parity: { marker: true, head: true, process_alive: true, process_counting: true },
  child_cost: null, agent: "", error: null, cleanup: [], ...over,
});

describe("cloud fork placement", () => {
  test("p95 is the nearest-rank 95th percentile", () => {
    expect(p95([])).toBeNull();
    expect(p95([5])).toBe(5);
    expect(p95([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])).toBe(10);
    expect(p95(Array.from({ length: 20 }, (_, i) => i + 1))).toBe(19);
  });
  test("facts reads key=value lines", () => {
    expect(facts("marker=abc\nhead=123\nnoise\ncount=4:7")).toEqual({ marker: "abc", head: "123", count: "4:7" });
  });

  test("parity needs the same marker and head and a live, counting process", () => {
    const parent = { marker: "m", head: "h" };
    expect(parity(parent, { marker: "m", head: "h", alive: "1", count: "3:6" })).toEqual({ marker: true, head: true, process_alive: true, process_counting: true });
    expect(parity(parent, { marker: "x", head: "h", alive: "0", count: "3:3" })).toEqual({ marker: false, head: true, process_alive: false, process_counting: false });
    expect(parity({}, {}).marker).toBe(false);
  });

  test("the verdict passes only when every run kept parity", () => {
    expect(verdict([row({}), row({ run: 2, fork_call_ms: 5000 })], {}).pass).toBe(true);
    const v = verdict([row({}), row({ run: 2, parity: null, error: "fork: HTTP 403" })], {});
    expect(v.pass).toBe(false);
    expect(v.parity_ok).toBe(1);
    expect(v.fork_call_ms.median).toBe(6000);
    expect(verdict([], {}).pass).toBe(false);
  });

  test("the paused arm is summarised on its own, with its pause time", () => {
    const a = armSummary([row({ parent_paused: true, pause_ms: 900, fork_call_ms: 3000 }), row({ run: 2, parent_paused: true, pause_ms: 1100, fork_call_ms: 4000 })]);
    expect(a.pass).toBe(true);
    expect(a.runs).toBe(2);
    expect(a.fork_call_ms.median).toBe(3000);
    expect(a.pause_ms.median).toBe(900);
    expect(armSummary([row({ parent_paused: true, parity: null })]).pass).toBe(false);
  });

  test("the commands name the marker, repo and counter", () => {
    expect(setupCommand("n1")).toContain("printf '%s' 'n1'");
    expect(setupCommand("n1")).toContain("setsid");
    expect(parityCommand()).toContain("kill -0");
  });
});
