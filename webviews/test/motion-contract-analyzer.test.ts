// The motion contract's arithmetic (support/motionContract.ts) on synthetic frames: each of its four
// checks fails the motion it is meant to catch and passes the one it is meant to allow.
import { describe, expect, test } from "bun:test";
import {
  analyzeMotion,
  contractFailures,
  SLOT_MS,
  type ElementSample,
  type MotionFrame,
  type MotionRecording,
} from "./support/motionContract";

/// Frames at 120 Hz; `at(i)` gives each frame's elements.
function frames(count: number, at: (index: number) => Partial<Record<string, Partial<ElementSample>>>, slot = SLOT_MS) {
  const out: MotionFrame[] = [];
  for (let index = 0; index < count; index += 1) {
    const els: Record<string, ElementSample> = {};
    for (const [key, el] of Object.entries(at(index))) if (el) els[key] = { top: 0, height: 20, opacity: 1, ...el };
    out.push({ t: index * slot, els, scrollTop: 0, fromEnd: 0, block: 2, marks: [] });
  }
  return { frames: out, animations: [] } satisfies MotionRecording;
}
/// The send curve's ease-out over `n` frames from `from` to `to`, starting at frame `start`.
const ease = (index: number, start: number, n: number, from: number, to: number) => {
  const p = Math.min(1, Math.max(0, (index - start) / n));
  return from + (to - from) * (1 - (1 - p) ** 3);
};

describe("motion contract", () => {
  test("one fast move of everything on one curve passes", () => {
    const report = analyzeMotion(
      frames(40, (i) => ({ a: { top: ease(i, 5, 12, 100, 40) }, b: { top: ease(i, 5, 12, 200, 140) } })),
    );
    expect(contractFailures(report)).toEqual([]);
    expect(report.velocityMismatch).toBe(0);
  });

  test("(a) a 300 ms settle fails", () => {
    const report = analyzeMotion(frames(60, (i) => ({ a: { top: ease(i, 2, 36, 100, 40) } })));
    expect(report.settleMs).toBeGreaterThan(150);
    expect(contractFailures(report).some((line) => line.startsWith("(a)"))).toBe(true);
  });

  test("(b) a dropped slot and a long block fail", () => {
    const recording = frames(20, () => ({ a: { top: 0 } }));
    recording.frames.forEach((frame, i) => (frame.t = i < 10 ? i * SLOT_MS : (i + 2) * SLOT_MS));
    recording.frames[12]!.block = 30;
    const report = analyzeMotion(recording);
    expect(report.dropped).toBe(2);
    expect(contractFailures(report).filter((line) => line.startsWith("(b)")).length).toBeGreaterThanOrEqual(2);
  });

  test("(c) a composer that snaps while the rows ease is not together", () => {
    const report = analyzeMotion(
      frames(40, (i) => ({ row: { top: ease(i, 5, 12, 100, 40) }, composer: { top: i < 6 ? 500 : 545 } })),
    );
    expect(report.endSkew).toBeGreaterThan(0);
    expect(report.velocityMismatch).toBeGreaterThan(0.5);
    expect(contractFailures(report).some((line) => line.startsWith("(c)"))).toBe(true);
  });

  test("(d) a second correction after rest, and a row that grows over frames, fail", () => {
    const twice = analyzeMotion(frames(40, (i) => ({ a: { top: i < 5 ? 100 : i < 10 ? 60 : i < 20 ? 60 : 58 } })));
    expect(twice.movedTwice).toEqual(["a"]);
    const grows = analyzeMotion(frames(20, (i) => (i < 3 ? {} : { a: { height: Math.min(80, 20 + (i - 3) * 10) } })));
    expect(grows.slowGrowth).toEqual(["a"]);
    // A row that comes in at its height passes.
    const whole = analyzeMotion(frames(20, (i) => (i < 3 ? {} : { a: { height: 80 } })));
    expect(whole.slowGrowth).toEqual([]);
  });
});
