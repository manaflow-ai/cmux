import { expect, test } from "bun:test";
import { causeOf, phasesOf, runWakeEcho, settle, summarize, wakeEchoMarkdown, type WakeCycle } from "./cloud-wake-echo.ts";

const cycle = (i: number, ok: boolean, marks: WakeCycle["marks_ms"]): WakeCycle => ({
  i, ok, error: ok ? "" : "boom", at: "", paused_ms: 1, answered_ms: 1, first_exec_ms: 1, offset_ms: 0, offset_rtt_ms: 1, offset_pre_ms: 0,
  marks_ms: marks, phases: phasesOf(marks).phases, warnings: [], guest: null, state_json: false, state_wake: null,
});

test("net_up and pty_attach both count from resumed (they run side by side); echo from max(input, attach)", () => {
  const { phases } = phasesOf({ resumed: 1000, net_up: 1500, pty_attach: 1700, input: 1690, echo: 1750 });
  expect(phases).toEqual({ restore: 1000, net_up: 500, pty_attach: 700, echo: 50, total: 1750 });
  // Run 45475656502's shape: the attach lands before the network is up. Neither phase goes negative.
  const early = phasesOf({ resumed: 1000, net_up: 1080, pty_attach: 1020, input: 1020, echo: 1023 });
  expect(early.phases).toMatchObject({ net_up: 80, pty_attach: 20 });
  expect(early.warnings).toEqual([]);
  // net up before the guest ran again (clock error): negative and warned.
  const odd = phasesOf({ resumed: 1000, net_up: 900, pty_attach: 1100, input: 1100, echo: 1120 });
  expect(odd.phases.pty_attach).toBe(100);
  expect(odd.warnings.length).toBe(1);
});

test("causes: a lost terminal is the product's, counted apart from machine-state failures", () => {
  expect(causeOf({ error: 'guest probe: attach: RuntimeError: attach refused: {"error": "unknown surface 6"}', guest: { surface_lost: { same_daemon: true } } })).toBe("daemon lost the terminal across the wake (product)");
  expect(causeOf({ error: "x", guest: { surface_lost: { same_daemon: false } } })).toBe("daemon restarted across the wake (product)");
  expect(causeOf({ error: "machine read pausing before the cycle", guest: null })).toBe("machine state");
});

test("settle waits out pausing by a deadline", async () => {
  const seq = ["pausing", "pausing", "paused"];
  let t = 0;
  expect(await settle(async () => seq.shift() ?? "paused", 10_000, async (ms) => { t += ms; }, () => t)).toBe("paused");
  await expect(settle(async () => "pausing", 2_000, async (ms) => { t += ms; }, () => t)).rejects.toThrow(/did not settle/);
});

test("a cycle after a pausing read settles, wakes and runs; a failure streak reports a stop", async () => {
  let status = "pausing";
  const reads: string[] = [];
  const stops: string[] = [];
  const cycles = await runWakeEcho({
    exec: async () => ({ code: 1, stdout: "", stderr: "down" }),
    guest: "", netHost: "h", netPort: 443, holdMs: 0, log: () => {}, onCycle: () => {}, onStop: (w) => stops.push(w),
    status: async () => { reads.push(status); const s = status; if (status === "pausing") status = "paused"; return s; },
    pause: async () => 0, wake: async () => { status = "running"; }, sleep: async () => {}, failStreak: 2, settleMs: 1_000,
  }, 5);
  // pausing, then paused: woken, read running, and the cycle goes on (to its arm, which this fake exec fails).
  expect(reads.slice(0, 3)).toEqual(["pausing", "paused", "running"]);
  expect(cycles.length).toBe(2);
  expect(cycles[0]!.error).toMatch(/^arm:/);
  expect(stops).toEqual(["2 failed cycles in a row after 2 of 5"]);
});

test("failed cycles count apart; percentiles over echoed; biggest phase", () => {
  const cs = [cycle(0, true, { resumed: 1000, net_up: 1100, pty_attach: 1200, input: 1200, echo: 1250 }), cycle(1, false, {}), cycle(2, true, { resumed: 3000, net_up: 3100, pty_attach: 3200, input: 3200, echo: 3250 })];
  const s = summarize(cs);
  expect([s.cycles, s.echoed, s.failed, s.biggest]).toEqual([3, 2, 1, "restore"]);
  expect(s.rows.find((r) => r.phase === "total")).toMatchObject({ n: 2, p50: 1250, p95: 3250 });
  expect(wakeEchoMarkdown(cs, { machine: "m" })).toContain("#1 (other): boom");
});
