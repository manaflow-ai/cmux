// The chat simulator's seek (src/agent-session/acpmux/sim/seek.ts): a recording starts at the scenario's
// interesting state, with every step before it applied at once and the rest on their recorded spacing.
//
// Leo, 2026-11-22: "that clip goes for 1 minute long and the only relevant and differentiating bit is at
// the last 10 seconds. so you guys need to be able to set these scenarios up faster and better and record
// better."
import { describe, expect, test } from "bun:test";
import { createSimulation } from "../src/agent-session/acpmux/sim/run";
import type { SimStep } from "../src/agent-session/acpmux/sim/script";
import { seekFromArgs, seekPlan } from "../src/agent-session/acpmux/sim/seek";
import { SCENARIOS } from "../src/agent-session/acpmux/sim/scenarios";

const T = 1_000_000;
const steps: SimStep[] = [
  { type: "event", seq: 1, at: T, label: "a" },
  { type: "event", seq: 2, at: T + 1000, label: "b" },
  { type: "reader", at: T + 2000, label: "scroll", reader: { scroll: "top" } },
  { type: "event", seq: 5, at: T + 5000, label: "c" },
  { type: "event", seq: 6, at: T + 9000, label: "d" },
];

describe("chat simulator seek", () => {
  test("no seek: nothing applied at once, the steps' own spacing", () => {
    expect(seekPlan(steps)).toEqual({ start: 0, startAt: T, delays: [0, 1000, 1000, 3000, 4000] });
  });

  test("--start-at: steps before S apply at once, the first played waits from S", () => {
    expect(seekPlan(steps, { startAtMs: 4000 })).toEqual({ start: 3, startAt: T + 4000, delays: [1000, 4000] });
    // A step exactly at S plays (it is not in the prefix).
    expect(seekPlan(steps, { startAtMs: 5000 }).start).toBe(3);
  });

  test("--seek-to-event SEQ --lead S: start LEAD before the first event at or after SEQ", () => {
    expect(seekPlan(steps, { seekToSeq: 5, leadMs: 3500 })).toEqual({
      start: 2,
      startAt: T + 1500,
      delays: [500, 3000, 4000],
    });
    // A seq between records seeks to the next one; reader steps are never the target.
    expect(seekPlan(steps, { seekToSeq: 3 }).start).toBe(3);
  });

  test("clamps: a lead past the start or a negative start plays everything; a start past the end plays nothing", () => {
    expect(seekPlan(steps, { seekToSeq: 2, leadMs: 60_000 })).toEqual(seekPlan(steps));
    expect(seekPlan(steps, { startAtMs: -5 })).toEqual(seekPlan(steps));
    expect(seekPlan(steps, { startAtMs: 60_000 })).toEqual({ start: 5, startAt: T + 60_000, delays: [] });
    expect(seekPlan([], { startAtMs: 10 })).toEqual({ start: 0, startAt: 10, delays: [] });
  });

  test("flags: seconds on the command line, ms in the plan", () => {
    const args = (list: string[]) => (name: string) => {
      const at = list.indexOf(name);
      return at >= 0 ? list[at + 1] : undefined;
    };
    expect(seekFromArgs(args([]))).toBeUndefined();
    expect(seekFromArgs(args(["--start-at", "50"]))).toEqual({ startAtMs: 50_000 });
    expect(seekFromArgs(args(["--seek-to-event", "120", "--lead", "2.5"]))).toEqual({ seekToSeq: 120, leadMs: 2500 });
    expect(seekFromArgs(args(["--seek-to-event", "120"]))).toEqual({ seekToSeq: 120, leadMs: 0 });
  });

  test("the state at the start is exact: applying the prefix at once draws what playing it does", () => {
    for (const make of Object.values(SCENARIOS)) {
      const scenario = make();
      const plan = seekPlan(scenario.steps, {
        startAtMs: ((scenario.steps.at(-1)?.at ?? 0) - scenario.steps[0]!.at) / 2,
      });
      const played = createSimulation(scenario);
      let playedRows;
      for (let index = 0; index < plan.start; index += 1) {
        const rows = played.advance(index);
        if (rows) played.check(index);
        playedRows = rows ?? playedRows;
      }
      const seeked = createSimulation(scenario);
      let seekedRows;
      for (let index = 0; index < plan.start; index += 1) seekedRows = seeked.advance(index) ?? seekedRows;
      expect(seekedRows?.map((row) => [row.id, row.kind, row.text])).toEqual(
        playedRows?.map((row) => [row.id, row.kind, row.text]),
      );
      expect(seeked.state()).toEqual(played.state());
      expect(plan.delays.length).toBe(scenario.steps.length - plan.start);
    }
  });
});
