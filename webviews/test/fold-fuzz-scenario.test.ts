// The fold fuzzer's generator (test/browser/fold-fuzz.scenario.ts, scripts/fold-fuzz.ts): a seed is a chat,
// the same one every time, so a seed the fuzzer flags replays exactly; and the seeds cover what Leo named
// (2026-11-22: "steers coming in at various times and tool calls at various times and turn ends at various").
import { describe, expect, test } from "bun:test";
import { fuzzScenario, fuzzSpec, rng, SPLITS } from "./browser/fold-fuzz.scenario";
import { analyze, driftThreshold, type FuzzRun } from "../scripts/fold-fuzz";

describe("fold fuzz generator", () => {
  test("a seed always draws the same chat", () => {
    for (const seed of [1, 2, 77, 500, 123_456]) {
      const a = fuzzScenario(seed);
      const b = fuzzScenario(seed);
      expect(JSON.stringify(a)).toBe(JSON.stringify(b));
    }
  });

  test("different seeds draw different chats", () => {
    const shapes = new Set(Array.from({ length: 50 }, (_, i) => JSON.stringify(fuzzSpec(i + 1))));
    expect(shapes.size).toBe(50);
  });

  test("the PRNG is the same sequence for a seed", () => {
    const a = rng(42);
    const b = rng(42);
    for (let i = 0; i < 100; i += 1) expect(a.next()).toBe(b.next());
  });

  test("500 seeds cover every call count range, steer time, turn end, viewport and split", () => {
    const specs = Array.from({ length: 500 }, (_, i) => fuzzSpec(i + 1));
    expect(Math.min(...specs.map((s) => s.calls))).toBe(1);
    expect(Math.max(...specs.map((s) => s.calls))).toBeGreaterThan(150);
    expect(specs.every((s) => s.calls >= 1 && s.calls <= 200)).toBe(true);
    for (const at of ["early", "stream", "tool", "fold"])
      expect(specs.some((s) => s.steers.includes(at as never))).toBe(true);
    for (const ending of ["stream", "fold", "recap", "settled"])
      expect(specs.some((s) => s.ending === ending)).toBe(true);
    for (const split of Object.keys(SPLITS)) expect(specs.some((s) => s.split === split)).toBe(true);
    expect(specs.some((s) => s.viewport === "up") && specs.some((s) => s.viewport === "bottom")).toBe(true);
    expect(specs.some((s) => s.subagents > 0) && specs.some((s) => s.chatter > 0)).toBe(true);
    expect(new Set(specs.map((s) => s.recap)).size).toBeGreaterThan(4);
  });

  test("the fold turn's end and the window are inside the chat, and the late steers inside the window", () => {
    for (let seed = 1; seed <= 200; seed += 1) {
      const { scenario, foldAt, windowFrom, spec } = fuzzScenario(seed);
      expect(scenario.steps[foldAt]!.label).toBe("turn_result");
      expect(windowFrom).toBeLessThanOrEqual(foldAt);
      expect(windowFrom).toBeGreaterThanOrEqual(0);
      const steers = scenario.steps.filter(
        (step) => step.label.startsWith("steer:") || step.label.startsWith("prompt: steer"),
      );
      expect(steers.length).toBe(spec.steers.length);
      const late = spec.steers.filter((at) => at !== "early").length;
      const inWindow = scenario.steps
        .slice(windowFrom)
        .filter((step) => step.label.startsWith("steer:") || step.label.startsWith("prompt: steer")).length;
      expect(inWindow).toBeGreaterThanOrEqual(late);
    }
  });
});

describe("fold fuzz flags", () => {
  const frame = (t: number, rows: FuzzRun["samples"][number]["rows"], scrollHeight = 1000, folding = false) => ({
    t,
    folding,
    view: 600,
    scrollHeight,
    scrollTop: 400,
    rows,
  });
  const base = (samples: FuzzRun["samples"]): FuzzRun => ({
    look: "test",
    samples,
    marks: [
      { step: 9, t: 0, label: "turn_end" },
      { step: 10, t: 1, label: "turn_result" },
    ],
    view: 600,
    overflowAnchor: "none",
    foldAt: 10,
  });

  test("a row that grows and then shrinks is a grow; one move with a stop in it is two phases", () => {
    const heights = [40, 40, 60, 80, 60, 40, 40, 40, 40, 40];
    const tops = [100, 100, 100, 100, 100, 90, 90, 90, 80, 80];
    const run = base(heights.map((h, i) => frame(i * 16, [["a", tops[i]!, h, 1]])));
    const n = analyze(run, { viewport: "up" });
    if ("error" in n) throw new Error(n.error);
    expect(n.growPx).toBe(40);
    expect(n.phases.length).toBe(2);
  });

  test("a steady move is one phase, and nothing at all is zero", () => {
    const moving = base(Array.from({ length: 10 }, (_, i) => frame(i * 16, [["a", 100 - i * 5, 40, 1]])));
    const n = analyze(moving, { viewport: "up" });
    if ("error" in n) throw new Error(n.error);
    expect(n.phases.length).toBe(1);
    expect(n.growPx).toBe(0);
    expect(n.anchorDriftPx).toBe(-45);
    const still = analyze(base(Array.from({ length: 10 }, (_, i) => frame(i * 16, [["a", 100, 40, 1]]))));
    if ("error" in still) throw new Error(still.error);
    expect(still.phases.length).toBe(0);
  });

  test("the drift threshold sits in the widest gap of the data", () => {
    expect(driftThreshold([0, 0.3, 1, 1.5, 2, 2, 120, 200, 300])).toBeCloseTo(Math.round(Math.sqrt(2 * 120) * 10) / 10);
  });
});
