// The frame classification of bench/first-load-after-restart.bench.ts (bench/firstLoadFrames.ts): a
// first load whose first frame is its last counts nothing, and a pane that blanked after it had
// content, or whose composer or last row moved, counts each such frame (Leo, 2026-11-09: "the chat
// loading kinda flickered in and out and layout shifted").
import { describe, expect, test } from "bun:test";
import { classifyFrames, type FrameRecord, type FrameRow } from "../bench/firstLoadFrames";

const ROWS: FrameRow[] = [
  { id: "user-117", top: 120 },
  { id: "assistant-118", top: 260 },
  { id: "assistant-120", top: 540 },
];
const COMPOSER = { top: 680, height: 96 };

/// A frame at `t` ms, the copy's or the live page's, with the rows and composer given.
const frame = (t: number, overrides: Partial<FrameRecord> = {}): FrameRecord => ({
  t,
  copyShown: false,
  rows: ROWS,
  composer: COMPOSER,
  scrollTop: 4000,
  ...overrides,
});

describe("first load frames", () => {
  test("an identical copy-to-live swap counts no shift and no blank, and the first frame is final", () => {
    const frames = [
      frame(40, { copyShown: true }),
      frame(56, { copyShown: true }),
      // The live page takes over at the same boxes, a fraction of a pixel apart.
      frame(72, { rows: ROWS.map((row) => ({ ...row, top: row.top + 0.4 })), composer: { top: 680.5, height: 96 } }),
      frame(88),
    ];
    const metrics = classifyFrames(frames);
    expect(metrics.shiftFrames).toBe(0);
    expect(metrics.blankAfterContent).toBe(0);
    expect(metrics.firstContentMs).toBe(40);
    expect(metrics.finalFirstPaintMs).toBe(40);
  });

  test("a blank gap after content counts each blank frame, and a frame before content does not", () => {
    const frames = [
      frame(10, { rows: [], composer: null }),
      frame(40, { copyShown: true }),
      frame(56, { rows: [] }),
      frame(72, { rows: [] }),
      frame(3_100),
    ];
    const metrics = classifyFrames(frames);
    expect(metrics.blankAfterContent).toBe(2);
    expect(metrics.blankAt).toEqual([2, 3]);
    expect(metrics.firstContentMs).toBe(40);
    // The rows came back where they were: the gap is a blank, not a shift.
    expect(metrics.shiftFrames).toBe(0);
    expect(metrics.finalFirstPaintMs).toBe(3_100);
  });

  test("rows that come back after a gap at another place count as a shift", () => {
    const lower = ROWS.map((row) => ({ ...row, top: row.top + 30 }));
    const metrics = classifyFrames([frame(40), frame(56, { rows: [] }), frame(72, { rows: lower })]);
    expect(metrics.blankAfterContent).toBe(1);
    expect(metrics.shiftFrames).toBe(1);
    expect(metrics.shiftAt[0]!.index).toBe(2);
  });

  test("a composer that moves counts the frame it moved in", () => {
    const taller = { top: 660, height: 116 };
    const frames = [frame(40), frame(56, { composer: taller }), frame(72, { composer: taller })];
    const metrics = classifyFrames(frames);
    expect(metrics.shiftFrames).toBe(1);
    expect(metrics.shiftAt[0]!.index).toBe(1);
    expect(metrics.shiftAt[0]!.why).toContain("composer");
    expect(metrics.finalFirstPaintMs).toBe(56);
  });

  test("a bottom row replaced by another counts as a shift", () => {
    const replaced = [ROWS[0]!, ROWS[1]!, { id: "assistant-119", top: 540 }];
    const metrics = classifyFrames([frame(40), frame(56, { rows: replaced })]);
    expect(metrics.shiftFrames).toBe(1);
  });

  test("finalFirstPaintMs is the first frame of the last state, not of an earlier equal one", () => {
    const moved = ROWS.map((row) => ({ ...row, top: row.top - 200 }));
    const frames = [frame(40), frame(56, { rows: moved }), frame(72), frame(88), frame(104)];
    const metrics = classifyFrames(frames);
    // Frame 0 equals the final state, but the state changed after it, at 56 and back at 72.
    expect(metrics.finalFirstPaintMs).toBe(72);
    expect(metrics.shiftFrames).toBe(2);
  });

  test("no frames give no times", () => {
    const metrics = classifyFrames([]);
    expect(metrics.firstContentMs).toBeNull();
    expect(metrics.finalFirstPaintMs).toBeNull();
    expect(metrics.frames).toBe(0);
  });
});
