import { expect, test } from "bun:test";
import { phasesOf, summarize, wakeEchoMarkdown, type WakeCycle } from "./cloud-wake-echo.ts";

const cycle = (i: number, ok: boolean, marks: WakeCycle["marks_ms"]): WakeCycle => ({
  i, ok, error: ok ? "" : "boom", at: "", paused_ms: 1, answered_ms: 1, first_exec_ms: 1, offset_ms: 0, offset_rtt_ms: 1, offset_pre_ms: 0,
  marks_ms: marks, phases: phasesOf(marks).phases, warnings: [], guest: null, state_json: false, state_wake: null,
});

test("phases use max(resumed, net_up) and max(input, attach)", () => {
  const { phases } = phasesOf({ resumed: 1000, net_up: 1500, pty_attach: 1700, input: 1690, echo: 1750 });
  expect(phases).toEqual({ restore: 1000, net_up: 500, pty_attach: 200, echo: 50, total: 1750 });
  // net up before the guest ran again (clock error): pty_attach measured from resumed, net_up negative and warned.
  const odd = phasesOf({ resumed: 1000, net_up: 900, pty_attach: 1100, input: 1100, echo: 1120 });
  expect(odd.phases.pty_attach).toBe(100);
  expect(odd.warnings.length).toBe(1);
});

test("failed cycles count apart; percentiles over echoed; biggest phase", () => {
  const cs = [cycle(0, true, { resumed: 1000, net_up: 1100, pty_attach: 1200, input: 1200, echo: 1250 }), cycle(1, false, {}), cycle(2, true, { resumed: 3000, net_up: 3100, pty_attach: 3200, input: 3200, echo: 3250 })];
  const s = summarize(cs);
  expect([s.cycles, s.echoed, s.failed, s.biggest]).toEqual([3, 2, 1, "restore"]);
  expect(s.rows.find((r) => r.phase === "total")).toMatchObject({ n: 2, p50: 1250, p95: 3250 });
  expect(wakeEchoMarkdown(cs, { machine: "m" })).toContain("#1: boom");
});
