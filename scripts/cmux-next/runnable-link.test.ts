import { describe, expect, test } from "bun:test";
import { canaryCountCommand, facts, projectSetupCommand, SCRUB_COMMAND, usable, usableCommand, verdict, withRoom, type OpenRow } from "./runnable-link.ts";

const row = (over: Partial<OpenRow>): OpenRow => ({ run: 1, via: "link", copy: "m", resolve_ms: 1, fork_call_ms: 1, running_ms: 1, first_exec_ms: 1, scrub_ms: 1, usable_ms: 1, click_to_usable_ms: 20_000, canary_before_scrub: 1, canary_after_scrub: 0, facts: null, error: null, ...over });

describe("runnable link", () => {
  test("usable needs service, smoke, head and session", () => {
    expect(usable(facts("service=200\nsmoke=1\nhead=abc\nsession=1"), "abc")).toBe(true);
    expect(usable(facts("service=200\nsmoke=1\nhead=abc\nsession=skip"), "abc")).toBe(true);
    expect(usable(facts("service=000\nsmoke=1\nhead=abc\nsession=1"), "abc")).toBe(false);
    expect(usable(facts("service=200\nsmoke=0\nhead=abc\nsession=1"), "abc")).toBe(false);
    expect(usable(facts("service=200\nsmoke=1\nhead=def\nsession=1"), "abc")).toBe(false);
    expect(usable(facts("service=200\nsmoke=1\nhead=abc\nsession=0"), "abc")).toBe(false);
  });
  test("a copy that still holds the canary fails the verdict", () => {
    expect(verdict([row({})], [], {}).pass).toBe(true);
    expect(verdict([row({ canary_after_scrub: 1 })], [], {}).pass).toBe(false);
    expect(verdict([row({ click_to_usable_ms: null })], [], {}).pass).toBe(false);
  });
  test("speedup is baseline p50 over click p50", () => {
    const v = verdict([row({ click_to_usable_ms: 20_000 })], [{ run: 1, machine: "b", create_ms: 1, setup_ms: 1, usable_ms: 1, total_ms: 60_000, facts: null, error: null }], {});
    expect(v.speedup_p50).toBe(3);
  });
  test("commands parse as shell", async () => {
    for (const c of [projectSetupCommand(), usableCommand("s"), usableCommand(null), canaryCountCommand("sk-ant-canary-x"), SCRUB_COMMAND]) {
      const p = Bun.spawnSync(["bash", "-n", "-c", c]);
      expect(p.exitCode).toBe(0);
    }
  });
  test("a timed-out call is asked again twice, and that time is not counted as quota wait", async () => {
    let calls = 0;
    const [v, waited] = await withRoom(async () => { if (++calls < 3) throw new Error("The operation timed out."); return "ok"; });
    expect([v, waited, calls]).toEqual(["ok", 0, 3]);
    calls = 0;
    await expect(withRoom(async () => { calls++; throw new Error("The operation timed out."); })).rejects.toThrow("timed out");
    expect(calls).toBe(3);
  }, 20_000);
});
