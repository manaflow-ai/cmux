// support/turnTransitionReport.ts counts a move that comes after a row's arrival, while no text
// streams, as the transition's: the review of #39271 found a 100 px whole-thread jump as a call
// settled reading worstPx 0, because every quiet frame counted as the stream's own motion.
import { expect, test } from "bun:test";
import type { RowSample, Sample } from "./browser/send-stream-motion.harness";
import { transitionReport } from "./support/turnTransitionReport";

const row = (id: string, top: number, text = id): RowSample => ({
  id,
  top,
  height: 40,
  opacity: 1,
  animating: false,
  moving: false,
  inView: true,
  text,
});

/// A frame: the reply (`length` characters), the rows above it, the live line, and maybe a call's row.
function frame(t: number, phase: string, shift: number, length: number, call = false): Sample {
  const rows = [
    row("h6-user", 100 + shift),
    row("live-answer", 200 + shift, "x".repeat(length)),
    ...(call ? [row("live-activity-1", 250 + shift, "Read relay.ts")] : []),
    row("thinking-live", 300 + shift),
  ];
  return {
    t,
    phase,
    top: 0,
    lag: 0,
    scrollTop: 0,
    fromEnd: 0,
    tail: 0,
    length,
    rows,
    composer: 600,
    eventAt: t,
    animations: 0,
    started: 0,
  };
}

test("a whole-thread jump as a call settles counts, with no text streaming", () => {
  const samples = [
    frame(0, "stream", 0, 100),
    // The call's row lands (an arrival), then the chase settles it with one 100 px jump.
    frame(8, "tool-done", 0, 100, true),
    frame(16, "tool-done", 0, 100, true),
    frame(24, "tool-done", -100, 100, true),
    frame(32, "tool-done", -100, 100, true),
  ];
  const [window] = transitionReport(samples, ["tool-done"]);
  expect(window!.readingPx).toBe(100);
  expect(window!.worstPx).toBe(100);
  expect(window!.jumpFrames).toBe(1);
});

test("the same move as the reply's text grows is the stream's own", () => {
  const samples = [
    frame(0, "stream", 0, 100),
    frame(8, "segment", 0, 100),
    frame(16, "segment", -20, 160),
    frame(24, "segment", -40, 160),
  ];
  const [window] = transitionReport(samples, ["segment"]);
  expect(window!.readingPx).toBe(0);
  expect(window!.streamPx).toBe(20);
});
