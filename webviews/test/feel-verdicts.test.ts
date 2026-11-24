// The feel verdicts (test/feel/verdicts.ts) on made-up traces: each catches the bug it is named for
// (a rim off the hand, a jump, a stuck edge, a flip-flop, churn, a pop) and passes the motion it should.
// Leo, 2026-11-22: "these should be doable via automation. the "feel" and "vibes" thing."
import { describe, expect, test } from "bun:test";
import type { Box, FeelEvent, FeelFrame, FeelTrace } from "./feel/trace";
import { churn, continuity, flips, follow, still, Verdicts } from "./feel/verdicts";
import { dragPath, rng } from "./feel/cursor";

const FRAME = 1000 / 60;
const box = (y: number, h = 40): Box => ({ x: 0, y, w: 200, h });

/** A drag trace: the hand presses at y = `from`, moves through `hand` (one point a frame), lets go;
 *  `edge(handY, i)` says where the tray's top is drawn each frame; `after` frames follow the release. */
function dragTrace(from: number, hand: number[], edge: (y: number, i: number) => number, after = 5): FeelTrace {
  const frames: FeelFrame[] = [];
  const events: FeelEvent[] = [];
  const frame = (t: number, y: number, top: number, buttons: number): FeelFrame => ({
    t,
    pointer: { x: 50, y, buttons },
    boxes: { tray: box(top) },
    texts: {},
    states: {},
    shift: 0,
  });
  frames.push(frame(0, from, edge(from, -1), 0));
  events.push({ t: 1, type: "pointerdown", x: 50, y: from, buttons: 1, detail: 1 });
  hand.forEach((y, i) => frames.push(frame((i + 1) * FRAME, y, edge(y, i), 1)));
  const end = (hand.length + 1) * FRAME;
  events.push({ t: end - 1, type: "pointerup", x: 50, y: hand.at(-1) ?? from, buttons: 0, detail: 1 });
  const last = frames.at(-1)!.boxes.tray!.y;
  for (let i = 0; i < after; i++) frames.push(frame(end + i * FRAME, hand.at(-1) ?? from, last, 0));
  return { frames, events };
}

const up = (from: number, by: number, steps: number) =>
  Array.from({ length: steps }, (_, i) => from - (by * (i + 1)) / steps);

describe("follow", () => {
  test("an edge that moves 1:1 with the hand from the grab point: no error, no jump, full coverage", () => {
    const report = follow(
      dragTrace(300, up(300, 60, 30), (y) => y - 4),
      { box: "tray", edge: "top" },
    );
    expect(report.maxError).toBe(0);
    expect(report.jumps).toEqual([]);
    expect(report.coverage).toBe(1);
    expect(report.grabOffset).toBe(-4);
  });

  test("a frame of lag is forgiven", () => {
    const hand = up(300, 60, 30);
    const report = follow(
      dragTrace(300, hand, (y, i) => (i <= 0 ? 296 : hand[i - 1]! - 4)),
      { box: "tray", edge: "top" },
    );
    expect(report.maxError).toBe(0);
    expect(report.jumps).toEqual([]);
  });

  test("an edge that drifts off the hand (moves at 1.5x) reads its error", () => {
    const report = follow(
      dragTrace(300, up(300, 60, 30), (y) => 296 + (y - 300) * 1.5),
      { box: "tray", edge: "top" },
    );
    expect(report.maxError).toBeGreaterThan(20);
  });

  test("an edge that jumps a line mid-drag reads a jump", () => {
    const report = follow(
      dragTrace(300, up(300, 60, 30), (y, i) => y - 4 - (i >= 15 ? 28 : 0)),
      { box: "tray", edge: "top" },
    );
    expect(report.jumps.length).toBeGreaterThan(0);
    expect(report.jumps[0]!.by).toBeGreaterThanOrEqual(24);
  });

  test("a stuck edge is not 'on the hand': its coverage is 0", () => {
    const report = follow(
      dragTrace(300, up(300, 60, 30), () => 296),
      { box: "tray", edge: "top" },
    );
    expect(report.coverage).toBe(0);
  });

  test("inside the slop the edge is expected to hold still", () => {
    const report = follow(
      dragTrace(300, [299, 298, 297], () => 296),
      { box: "tray", edge: "top", slop: 8 },
    );
    expect(report.maxError).toBe(0);
  });

  test("a snap-along edge resting on a line within its detent is on the hand; one between lines is not", () => {
    // Lines every 28 px from 296 up; the rim settles on one when 1:1 is within 5 px of it.
    const detents = { at: [296, 268, 240, 212], within: 5 };
    const snap = (ask: number) => detents.at.find((at) => Math.abs(at - ask) <= 5) ?? ask;
    const hand = up(300, 60, 30);
    const snapping = follow(
      dragTrace(300, hand, (y) => snap(y - 4)),
      { box: "tray", edge: "top", detents },
    );
    expect(snapping.maxError).toBe(0);
    expect(snapping.jumps).toEqual([]);
    expect(snapping.releaseLanded).toBe(true);
    // Stuck 12 px short of the hand, far from any line: off the hand however detented.
    const stuck = follow(
      dragTrace(300, hand, (y, i) => (i >= 15 ? y + 8 : y - 4)),
      { box: "tray", edge: "top", detents },
    );
    expect(stuck.maxError).toBeGreaterThanOrEqual(7);
  });

  test("a release that lands on a line reads as landed", () => {
    const trace = dragTrace(300, up(300, 50, 25), (y) => y - 4);
    for (const frame of trace.frames.slice(-3)) frame.boxes.tray = box(240);
    const report = follow(trace, { box: "tray", edge: "top", detents: { at: [268, 240], within: 5 } });
    expect(report.releaseLanded).toBe(true);
    expect(report.releaseMove).toBe(6);
  });

  test("a move after the release is read", () => {
    const trace = dragTrace(300, up(300, 60, 30), (y) => y - 4);
    for (const frame of trace.frames.slice(-3)) frame.boxes.tray = box(frame.boxes.tray!.y + 14);
    expect(follow(trace, { box: "tray", edge: "top" }).releaseMove).toBe(14);
  });
});

describe("still, flips", () => {
  const trace = (tops: number[], open: (string | null)[]): FeelTrace => ({
    frames: tops.map((y, i) => ({
      t: i * FRAME,
      pointer: null,
      boxes: { tray: box(y) },
      texts: {},
      states: { open: open[i] ?? null },
      shift: i === 2 ? 0.05 : 0,
    })),
    events: [],
  });

  test("a click that changes nothing reads nothing", () => {
    const report = still(trace([300, 300, 300], ["true", "true", "true"]));
    expect(report.moved.tray).toBe(0);
    expect(report.changed.open).toEqual(["true"]);
  });

  test("a click that folds the tray reads its move and its state change", () => {
    const report = still(trace([300, 400, 580], ["true", null, null]));
    expect(report.moved.tray).toBe(280);
    expect(report.changed.open).toEqual(["true", null]);
    expect(report.shift).toBe(0.05);
  });

  test("a fold point without hysteresis flips each time the hand crosses it", () => {
    expect(flips(trace([0, 0, 0, 0, 0], ["true", null, "true", null, "true"]), "open")).toBe(4);
    expect(flips(trace([0, 0, 0, 0, 0], ["true", null, null, null, null]), "open")).toBe(1);
  });
});

describe("churn", () => {
  const trace = (lines: string[], width = (text: string) => text.length * 7): FeelTrace => ({
    frames: lines.map((text, i) => ({
      t: i * FRAME,
      pointer: null,
      boxes: {},
      texts: { latest: { text, width: width(text) } },
      states: {},
      shift: 0,
    })),
    events: [],
  });

  test("a line swapping every 6 frames reads 10 swaps a second and a 100 ms hold", () => {
    const words = ["Bash", "Read SubagentTray.tsx", "Grep latestLine"];
    const lines = Array.from({ length: 61 }, (_, i) => words[Math.floor(i / 6) % 3]!);
    const report = churn(trace(lines), "latest");
    expect(report.swapsPerSecond).toBe(10);
    expect(report.shortestHold).toBe(100);
    expect(report.distinct).toBe(3);
    expect(report.timeline[0]).toEqual({ t: 100, text: "Read SubagentTray.tsx" });
  });

  test("a calm line (one swap a second, one width) reads that", () => {
    const lines = Array.from({ length: 121 }, (_, i) => (Math.floor(i / 60) % 2 ? "Grep" : "Bash"));
    const report = churn(
      trace(lines, () => 120),
      "latest",
    );
    expect(report.swapsPerSecond).toBe(1);
    expect(report.shortestHold).toBe(1000);
    expect(report.widthChangesPerSecond).toBe(0);
  });
});

describe("continuity", () => {
  const trace = (tops: number[]): FeelTrace => ({
    frames: tops.map((y, i) => ({
      t: i * FRAME,
      pointer: null,
      boxes: { tray: box(y) },
      texts: {},
      states: {},
      shift: 0,
    })),
    events: [],
  });

  test("an eased move reads one move, no reversal, no pop", () => {
    const eased = Array.from({ length: 20 }, (_, i) => 300 - 60 * (1 - (1 - i / 19) ** 3));
    const report = continuity(trace([300, 300, 300, ...eased, 240, 240, 240]), "tray", "top");
    expect(report.moves).toBe(1);
    expect(report.reversals).toBe(0);
    expect(report.maxStepShare).toBeLessThan(0.2);
  });

  test("a snap (all in one frame) reads as a pop, a bounce as a reversal, a stutter as two moves", () => {
    expect(continuity(trace([300, 300, 240, 240]), "tray", "top").maxStepShare).toBe(1);
    expect(continuity(trace([300, 280, 260, 250, 255, 255]), "tray", "top").reversals).toBe(1);
    expect(continuity(trace([300, 290, 290, 290, 290, 280, 280]), "tray", "top").moves).toBe(2);
  });
});

describe("the cursor's paths", () => {
  test("are the same every run (seeded) and end where they were sent", () => {
    const from = { x: 10, y: 300 };
    const to = { x: 10, y: 240 };
    for (const style of ["slow", "fast", "jitter", "burst", "overshoot"] as const) {
      const path = dragPath(from, to, style, 3);
      expect(dragPath(from, to, style, 3)).toEqual(path);
      expect(path.at(-1)!.x).toBeCloseTo(to.x);
      expect(path.at(-1)!.y).toBeCloseTo(to.y);
    }
    expect(Math.min(...dragPath(from, to, "overshoot").map((step) => step.y))).toBeCloseTo(220);
    expect(rng(1)()).toBe(rng(1)());
  });
});

test("Verdicts collects pass and fail with their limits", () => {
  const v = new Verdicts();
  v.atMost("jumps", 0, 0);
  v.atLeast("hold", 100, 800, " ms");
  v.equals("open", ["true"], ["true"]);
  expect(v.failed).toEqual([{ check: "hold", pass: false, measured: "100 ms", limit: "≥ 800 ms" }]);
});
