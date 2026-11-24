import { describe, expect, test } from "bun:test";
import { RISKY_STEP, checkpointKept, dirtyCommand, facts, parity, parityCommand, setupCommand, verdict, workCommand, type RunRow } from "./cloud-fork-placement.ts";

const row = (over: Partial<RunRow>): RunRow => ({
  run: 1, parent: "vm_p", child: "vm_c", parent_ready_ms: 1, fork_call_ms: 6000, fork_status: 200,
  fork_to_first_exec_ms: 7000, parity: { marker: true, head: true, process_alive: true, process_counting: true },
  child_cost: null, agent: "", error: null, cleanup: [], ...over,
});

describe("cloud fork placement", () => {
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

  test("the commands name the marker, repo and counter", () => {
    expect(setupCommand("n1")).toContain("printf '%s' 'n1'");
    expect(setupCommand("n1")).toContain("setsid");
    expect(parityCommand()).toContain("kill -0");
  });

  test("--risky: the checkpoint held only when the parent lost the work and the copy kept it", () => {
    expect(checkpointKept("w", "", "w")).toEqual({ parent_lost_work: true, copy_kept_work: true });
    expect(checkpointKept("w", "w", "")).toEqual({ parent_lost_work: false, copy_kept_work: false });
    expect(checkpointKept(undefined, "", "")).toEqual({ parent_lost_work: false, copy_kept_work: false });
    const held = { step_exit: 0, parent_lost_work: true, copy_kept_work: true };
    expect(verdict([row({ risky: held })], {}).pass).toBe(true);
    expect(verdict([row({ risky: { ...held, copy_kept_work: false } })], {}).pass).toBe(false);
    expect(verdict([row({ risky: null, error: "fork: HTTP 500" })], {}).pass).toBe(false);
    expect(RISKY_STEP).toContain("git reset -q --hard");
    expect(dirtyCommand("n1")).toContain("work-n1");
    expect(workCommand()).toContain("sha256sum");
  });
});
