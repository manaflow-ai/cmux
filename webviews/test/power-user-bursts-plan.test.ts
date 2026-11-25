// The power-user harness's plan and judge (support/powerUserBursts.ts), without a page: a seed
// replays the same run, draft kinds never overlap, and the judge flags what Leo named.
import { describe, expect, test } from "bun:test";
import {
  BURST_KINDS,
  classNumbers,
  draftDiff,
  judge,
  knownBreach,
  planRun,
  reversalFromWheel,
  type BurstRecord,
} from "./support/powerUserBursts";

const options = { waves: 200, width: 1100, height: 800, sessions: 3 };

describe("planRun", () => {
  test("a seed replays the same run, another seed another", () => {
    expect(planRun(7, options)).toEqual(planRun(7, options));
    expect(JSON.stringify(planRun(7, options))).not.toBe(JSON.stringify(planRun(8, options)));
  });

  test("covers every input class and overlaps bursts", () => {
    const waves = planRun(20261122, options);
    const kinds = new Set(waves.flatMap((wave) => wave.bursts.map((burst) => burst.kind)));
    expect([...kinds].sort()).toEqual([...BURST_KINDS].sort());
    expect(waves.some((wave) => wave.bursts.length > 1)).toBe(true);
  });

  test("two draft kinds, or a draft and a switch, never share a wave", () => {
    for (const wave of planRun(3, options)) {
      const kinds = wave.bursts.map((burst) => burst.kind);
      const drafts = kinds.filter((kind) => ["type", "paste", "image", "send"].includes(kind));
      expect(drafts.length).toBeLessThanOrEqual(1);
      if (drafts.length) expect(kinds).not.toContain("switch");
    }
  });

  test("typing runs at 15 keys a second or faster", () => {
    for (const wave of planRun(11, options))
      for (const burst of wave.bursts)
        if (burst.kind === "type") expect(1000 / burst.gapMs).toBeGreaterThanOrEqual(14.9);
  });
});

describe("draftDiff", () => {
  test("whole, dropped and reordered", () => {
    expect(draftDiff("hello", "hello")).toEqual({ dropped: 0, reordered: false });
    expect(draftDiff("hello", "helo")).toEqual({ dropped: 1, reordered: false });
    expect(draftDiff("hello", "hlelo")).toEqual({ dropped: 0, reordered: true });
  });
});

describe("judge", () => {
  const record = (over: Partial<BurstRecord> = {}): BurstRecord => ({
    kind: "flick",
    wave: 0,
    frameMs: Array.from({ length: 100 }, () => 16.7),
    inputToPaintMs: [8, 12, 16],
    strayFrames: 0,
    strayWorstPx: 0,
    blankFrames: 0,
    ...over,
  });

  test("a clean run passes", () => {
    expect(judge(classNumbers([record()]), [])).toEqual([]);
  });

  test("flags long frames, stray shifts, blanks, dropped keys and console errors", () => {
    const slow = record({
      frameMs: [...Array.from({ length: 90 }, () => 16.7), ...Array.from({ length: 10 }, () => 120)],
    });
    const typed = record({ kind: "type", caretLagMs: [10, 90, 90, 90], droppedKeys: 2, reordered: true });
    const shifted = record({ kind: "sweep", strayFrames: 1, strayWorstPx: 6, blankFrames: 2 });
    const what = judge(classNumbers([slow, typed, shifted]), ["boom"]).map((breach) => `${breach.kind} ${breach.what}`);
    expect(what).toEqual(
      expect.arrayContaining([
        "flick frame_p99_ms",
        "flick long_frame_share",
        "type caret_lag_p95_ms",
        "type dropped_keys",
        "type reordered",
        "sweep stray_worst_px",
        "sweep blank_frames",
        "console error",
      ]),
    );
  });

  test("a heavy paste's own long frame is not a frame breach, its blank frames still are", () => {
    const paste = record({ kind: "paste", frameMs: [16.7, 400], blankFrames: 1 });
    expect(judge(classNumbers([paste]), []).map((breach) => breach.what)).toEqual(["blank_frames"]);
  });
});

describe("reversalFromWheel", () => {
  test("a reversal right after the wheel turned that way is the person's", () => {
    // Rows drop (dy > 0) when the wheel scrolls up (deltaY < 0).
    expect(reversalFromWheel([[], [-1], [], []], 3, 40)).toBe(true);
    expect(reversalFromWheel([[], [1], [], []], 3, 40)).toBe(false);
    expect(reversalFromWheel([[-1], [], [], [], [], [], [], [], [], []], 9, 40)).toBe(false);
  });
});

describe("judge against the idle stream", () => {
  test("a slow runner's own frames are not a class's breach", () => {
    const slow = {
      kind: "sweep" as const,
      wave: 0,
      frameMs: Array.from({ length: 100 }, () => 40),
      inputToPaintMs: [40],
      strayFrames: 0,
      strayWorstPx: 0,
      blankFrames: 0,
    };
    expect(judge(classNumbers([slow]), []).map((breach) => breach.what)).toContain("frame_p95_ms");
    expect(
      judge(classNumbers([slow]), [], undefined, { frame_p95_ms: 33, frame_p99_ms: 50, long_frame_share: 0 }),
    ).toEqual([]);
  });

  test("console errors fold to one breach per message", () => {
    const breaches = judge({}, ["dup key row-1", "dup key row-2", "other"]);
    expect(breaches.map((breach) => breach.value)).toEqual(["2x dup key row-N", "1x other"]);
  });
});

describe("knownBreach", () => {
  test("a filed breach names its issue, for any kind under `*`; another engine's or metric's does not", () => {
    expect(knownBreach("chromium", { kind: "resize", what: "blank_frames", value: 4, budget: 0 })).toMatch(/#\d+$/);
    expect(knownBreach("chromium", { kind: "sweep", what: "blank_frames", value: 4, budget: 0 })).toMatch(/#\d+$/);
    expect(knownBreach("firefox", { kind: "sweep", what: "blank_frames", value: 4, budget: 0 })).toBeUndefined();
    expect(knownBreach("chromium", { kind: "type", what: "dropped_keys", value: 1, budget: 0 })).toBeUndefined();
    const duplicate = "3x Encountered two children with the same key, `%s`.";
    expect(knownBreach("webkit", { kind: "console", what: "error", value: duplicate, budget: "none" })).toMatch(
      /#\d+$/,
    );
    expect(
      knownBreach("webkit", { kind: "console", what: "error", value: "1x other", budget: "none" }),
    ).toBeUndefined();
  });
});
