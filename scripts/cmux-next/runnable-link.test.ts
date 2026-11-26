import { describe, expect, test } from "bun:test";
import { canaryCountCommand, facts, projectSetupCommand, SCRUB_COMMAND, usable, usableCommand, verdict, withRoom, strays, runTag, snapshotCensus, type OpenRow } from "./runnable-link.ts";

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
  test("the stray sweep takes this run's machines and old ones of this script, nothing else", () => {
    const now = 10 * 3600_000;
    const rows = [
      { id: "a", name: "runnable link rl-x parent", status: "running", created_at: now - 60_000 },
      { id: "b", name: "runnable link rl-y open 1", status: "running", created_at: now - 81 * 60_000 },
      { id: "c", name: "runnable link rl-y open 2", status: "running", created_at: now - 600_000 },
      { id: "d", name: "cloud journey auto jr-1", status: "running", created_at: 0 },
      { id: "e", name: "runnable link rl-x open 1", status: "deleted", created_at: now },
      { id: "f", name: "runnable link rl-x open 2", status: "running", created_at: now },
    ];
    expect(strays(rows, "rl-x", now, new Set(["f"]))).toEqual(["a", "b"]);
  });

  test("the sweep also takes snapshots: this run's by exact name, old ones by an ISO created_at", () => {
    const now = Date.parse("2026-11-25T21:00:00Z");
    const rows = [
      { id: "s1", name: "runnable link rl-x", status: "ready", created_at: "2026-11-25T20:59:00Z" },
      { id: "s2", name: "runnable link rl-old", status: "ready", created_at: "2026-11-25T17:00:00Z" },
      { id: "s3", name: "runnable link rl-new", status: "ready", created_at: "2026-11-25T20:30:00Z" },
      { id: "s4", name: "runnable link rl-nodate", status: "ready" },
      { id: "s5", name: "someone's snapshot", status: "ready", created_at: "2020-01-01T00:00:00Z" },
    ];
    expect(strays(rows, "rl-x", now, new Set())).toEqual(["s1", "s2"]);
  });

  test("the sweep takes the link API's own snapshots too (named by the mint's clientKey), never someone else's", () => {
    const now = Date.parse("2026-11-25T23:00:00Z");
    const rows = [
      { id: "l1", name: "link user_9 rl-x-mint", status: "ready", created_at: "2026-11-25T22:59:00Z" },
      { id: "l2", name: "link user_9 rl-old-mint", status: "ready", created_at: "2026-11-24T18:00:00Z" },
      { id: "l3", name: "link user_9 rl-old-mint-expiring", status: "ready", created_at: "2026-11-24T18:00:00Z" },
      { id: "l4", name: "link user_9 rl-new-mint", status: "ready", created_at: "2026-11-25T22:30:00Z" },
      { id: "l5", name: "link user_9 handoff-1", status: "ready", created_at: "2020-01-01T00:00:00Z" },
      { id: "l6", name: "cmux-1234", status: "ready", created_at: "2020-01-01T00:00:00Z" },
    ];
    expect(strays(rows, "rl-x", now, new Set())).toEqual(["l1", "l2", "l3"]);
    expect(runTag("runnable link rl-ab parent")).toBe("rl-ab");
    expect(runTag("runnable link rl-ab")).toBe("rl-ab");
    expect(runTag("link user_1 rl-ab-mint")).toBe("rl-ab");
    expect(runTag("link user_1 rl-ab-open-1")).toBeNull();
  });

  test("the snapshot census folds ids so the script that fills the slots shows by name", () => {
    const now = Date.parse("2026-11-25T22:00:00Z");
    const c = snapshotCensus([
      { name: "headless rl-abc123", status: "ready", created_at: "2026-11-25T12:00:00Z" },
      { name: "headless rl-def456", status: "ready", created_at: "2026-11-25T20:00:00Z" },
      { name: "gone", status: "deleted" },
    ], now);
    expect(c).toEqual({ total: 3, live: 2, oldest_h: 10, by_shape: { "headless rl-#": 2 } });
  });
});
