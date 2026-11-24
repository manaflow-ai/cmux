// The fold fuzzer's generator (test/browser/fold-fuzz.scenario.ts, scripts/fold-fuzz.ts): a seed is a chat,
// the same one every time, so a seed the fuzzer flags replays exactly; and the seeds cover what Leo named
// (2026-11-22: "steers coming in at various times and tool calls at various times and turn ends at various").
import { describe, expect, test } from "bun:test";
import { MOTION_MS, MOTION_SETTLE } from "../src/motion/scale.generated";
import { fuzzScenario, fuzzSpec, rng, SPLITS, strayScenario } from "./browser/fold-fuzz.scenario";
import { analyze, driftThreshold, type FuzzRun } from "../scripts/fold-fuzz";
import {
  onHouseCurve,
  stepClass,
  strayStarts,
  transcriptMoves,
  type AnimationStart,
  type Box,
  type MotionRecord,
} from "./support/transcriptMotion";

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
      // hq#18554's multi-line steer is one more.
      const sentSteer = spec.axes.send?.at === "steer" ? 1 : 0;
      expect(steers.length).toBe(spec.steers.length + sentSteer);
      const late = spec.steers.filter((at) => at !== "early").length + sentSteer;
      const inWindow = scenario.steps
        .slice(windowFrom)
        .filter((step) => step.label.startsWith("steer:") || step.label.startsWith("prompt: steer")).length;
      expect(inWindow).toBeGreaterThanOrEqual(late);
    }
  });
});

describe("hq#18554 axes", () => {
  const specs = Array.from({ length: 500 }, (_, i) => fuzzSpec(i + 1));
  test("500 seeds cover every send size with and without images, every tail, notice, load and width", () => {
    for (const lines of [1, 5, 30, 300])
      for (const attach of [true, false])
        for (const at of ["next", "steer"])
          expect(
            specs.some((s) => s.axes.send?.lines === lines && s.axes.send.attach === attach && s.axes.send.at === at),
          ).toBe(true);
    for (const tail of ["plain", "compaction", "queued"]) expect(specs.some((s) => s.axes.tail === tail)).toBe(true);
    for (const notice of ["none", "notice-turn", "land-send"])
      expect(specs.some((s) => s.axes.notice === notice)).toBe(true);
    expect(specs.some((s) => s.axes.tailTools > 0) && specs.some((s) => s.axes.background)).toBe(true);
    expect(specs.some((s) => s.axes.load > 1) && specs.some((s) => s.axes.load === 1)).toBe(true);
    expect(specs.some((s) => s.split === "wide") && specs.some((s) => s.split === "third")).toBe(true);
  });

  test("each axis lands in the chat where it says", () => {
    for (let seed = 1; seed <= 200; seed += 1) {
      const { scenario, foldAt, spec } = fuzzScenario(seed);
      const labels = scenario.steps.map((step) => step.label);
      const after = labels.slice(foldAt + 1);
      if (spec.axes.notice === "land-send")
        expect(after.some((l) => l.startsWith("tool start: acpmux send"))).toBe(true);
      if (spec.axes.notice !== "none") expect(after.some((l) => l.startsWith("incoming notice"))).toBe(true);
      if (spec.axes.tail === "queued") expect(after.some((l) => l.startsWith("prompt: queued"))).toBe(true);
      if (spec.axes.tail === "compaction")
        expect(labels.slice(0, foldAt).some((l) => l.startsWith("compaction"))).toBe(true);
      if (spec.axes.send?.at === "next") expect(after.some((l) => l.startsWith("prompt: line 1 of"))).toBe(true);
      const tail = labels.slice(0, foldAt).filter((l) => l.includes("# tail")).length;
      expect(tail).toBe(spec.axes.tailTools);
    }
  });
});

describe("the transcript motion detector", () => {
  const frame = (
    t: number,
    els: MotionRecord["frames"][number]["els"],
    extra: Partial<MotionRecord["frames"][number]> = {},
  ): MotionRecord["frames"][number] => ({
    t,
    scrollTop: 0,
    scrollHeight: 1000,
    clientHeight: 600,
    els,
    touched: [],
    animated: [],
    marks: [],
    ...extra,
  });
  const row = (y: number, h = 40): [Box, string] => [[0, y, 600, h], "row"];

  test("an untouched row that jumps is a move; one under a touched row that grew names it as the cause", () => {
    const record: MotionRecord = {
      frames: [
        frame(0, { "row:a": row(100), "row:b": row(140) }),
        frame(16, { "row:a": row(100, 70), "row:b": row(170) }, { touched: ["row:a"], marks: ["tool start: x"] }),
      ],
      animations: [],
      inputs: [],
    };
    const flags = transcriptMoves(record);
    expect(flags.map((f) => [f.kind, f.key, f.px])).toEqual([["move", "row:b", 30]]);
    expect(flags[0]!.cause).toEqual(["row:a +30"]);
    expect(stepClass(flags[0]!)).toBe("tool");
  });

  test("1 px is rounding; a touched row may change; an animated row is judged by its curve", () => {
    const record: MotionRecord = {
      frames: [
        frame(0, { "row:a": row(100), "row:b": row(140), "row:c": row(200) }),
        frame(
          16,
          { "row:a": row(101), "row:b": row(140, 90), "row:c": row(150) },
          { touched: ["row:b"], animated: ["row:c"] },
        ),
      ],
      animations: [
        {
          target: "row:c",
          properties: ["translate"],
          duration: MOTION_MS.standard,
          easing: MOTION_SETTLE,
          frame: 1,
        },
        { target: "div.acpmux-thread", properties: ["height"], duration: 400, easing: "linear", frame: 1 },
      ],
      inputs: [],
    };
    const flags = transcriptMoves(record);
    expect(flags.map((f) => [f.kind, f.key])).toEqual([["off-curve", "div.acpmux-thread"]]);
    expect(onHouseCurve({ easing: "ease-out", duration: MOTION_MS.micro })).toBe(true);
    expect(onHouseCurve({ easing: MOTION_SETTLE, duration: 480 })).toBe(false);
  });

  test("a script translate run (the follow chase) moves its rows on a curve; turning back is a bounce", () => {
    const glide = [100, 90, 80, 72, 66, 62];
    const smooth: MotionRecord = {
      frames: glide.map((y, i) =>
        frame(
          i * 16,
          { "row:a": row(y), "row:b": row(y + 40) },
          { driven: { "thread:0": [y - 100, ["row:a", "row:b"]] } },
        ),
      ),
      animations: [],
      inputs: [],
    };
    expect(transcriptMoves(smooth)).toEqual([]);
    const back = [100, 90, 80, 90, 85, 80];
    const bounce: MotionRecord = {
      ...smooth,
      frames: back.map((y, i) =>
        frame(
          i * 16,
          { "row:a": row(y), "row:b": row(y + 40) },
          { driven: { "thread:0": [y - 100, ["row:a", "row:b"]] } },
        ),
      ),
    };
    expect(transcriptMoves(bounce).map((f) => [f.kind, f.key, f.of, f.px])).toEqual([
      ["off-curve", "thread:0", "script", 10],
    ]);
    // Two frames are not a run: the rows they moved are moves.
    const short: MotionRecord = { ...smooth, frames: smooth.frames.slice(0, 2) };
    expect(transcriptMoves(short).map((f) => [f.kind, f.key])).toEqual([
      ["move", "row:a"],
      ["move", "row:b"],
    ]);
  });

  test("the reader's own scroll moves the rows and nothing is flagged; the dock moving with it is", () => {
    const record: MotionRecord = {
      frames: [
        frame(0, { "row:a": row(300), dock: [[0, 560, 600, 80], "dock"] }, { scrollTop: 400 }),
        frame(16, { "row:a": row(400), dock: [[0, 540, 600, 100], "dock"] }, { scrollTop: 300 }),
      ],
      animations: [],
      inputs: [10],
    };
    expect(transcriptMoves(record).map((f) => [f.kind, f.key])).toEqual([
      ["move", "dock"],
      ["resize", "dock"],
    ]);
    // The same scroll with no input is the page's: every row it moved is a move.
    expect(transcriptMoves({ ...record, inputs: [] }).filter((f) => f.key === "row:a").length).toBe(1);
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
    expect(driftThreshold([0, 0.3, 1, 1.5, 2, 2, 40, 60, 300])).toBeCloseTo(Math.round(Math.sqrt(2 * 40) * 10) / 10);
  });
});

// docs/design/transcript-animation-rules.md. Leo, 2026-11-22: "i scroll down, some bullshit ABOVE folds...?
// and plays an animation!?"
describe("stray animation starts", () => {
  const frame = (t: number, scrollTop: number): MotionRecord["frames"][number] => ({
    t,
    scrollTop,
    scrollHeight: 4000,
    clientHeight: 600,
    els: {},
    touched: [],
    animated: [],
    marks: [],
  });
  const start = (t: number, top: number, extra: Partial<AnimationStart> = {}): AnimationStart => ({
    target: "row:a",
    type: "waapi",
    what: "opacity",
    top,
    bottom: top + 40,
    view: 600,
    frame: Math.round(t / 16),
    t,
    ...extra,
  });
  const still = Array.from({ length: 40 }, (_, i) => frame(i * 16, 1000));
  const scrolled = Array.from({ length: 40 }, (_, i) => frame(i * 16, 1000 + i * 30));

  test("a start above or below the view is offscreen, whatever caused it", () => {
    const record: MotionRecord = {
      frames: still,
      animations: [],
      inputs: [],
      starts: [start(100, -300), start(120, 700, { target: "row:b" }), start(140, 100, { target: "row:c" })],
    };
    expect(strayStarts(record).map((f) => [f.kind, f.key])).toEqual([
      ["offscreen-start", "row:a"],
      ["offscreen-start", "row:b"],
    ]);
  });

  test("a start in view while the reader scrolls is a stray unless he aimed at the row or its data is new", () => {
    const record: MotionRecord = {
      frames: scrolled,
      animations: [],
      inputs: [80, 160, 240, 320],
      starts: [
        start(200, 100, { remount: true }),
        start(210, 100, { target: "row:b" }),
        start(220, 100, { target: "row:c" }),
      ],
      aimed: [[150, "row:b"]],
      arrived: { "row:c": 100 },
    };
    expect(strayStarts(record).map((f) => [f.kind, f.key])).toEqual([["scroll-start", "row:a"]]);
    expect(strayStarts(record)[0]!.detail).toContain("remount");
  });

  test("a start in view with the view still is the change the reader is looking at", () => {
    const record: MotionRecord = { frames: still, animations: [], inputs: [80], starts: [start(500, 100)] };
    expect(strayStarts(record)).toEqual([]);
  });

  test("a stray seed is the fuzz seed's turn with a sweep after it, and odd seeds end scrolled up", () => {
    for (const seed of [1, 2, 7, 40]) {
      const stray = strayScenario(seed);
      const plain = fuzzScenario(seed, stray.spec.viewport === "up" ? { viewport: "up" } : {});
      expect(stray.scenario.steps.slice(0, stray.sweepFrom)).toEqual(plain.scenario.steps);
      const sweep = stray.scenario.steps.slice(stray.sweepFrom);
      expect(sweep.every((step) => step.type === "reader")).toBe(true);
      expect(sweep.some((step) => step.label === "reader scroll top")).toBe(true);
      if (seed % 2 === 1) expect(stray.spec.viewport).toBe("up");
    }
    // The fuzz seed itself is unchanged by the stray corpus.
    expect(fuzzScenario(3)).toEqual(fuzzScenario(3, {}));
  });
});
