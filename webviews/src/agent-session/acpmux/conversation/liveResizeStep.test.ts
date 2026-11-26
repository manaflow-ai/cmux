import { describe, expect, it } from "bun:test";
import {
  continuesLiveResize,
  LIVE_RESIZE_MS,
  LIVE_RESUME_MS,
  resumesLiveResize,
  stepLiveResize,
  widthChanged,
  type LiveResizeClock,
} from "./liveResizeStep";

/// A drag, step by step: each width arrives `gap` ms after the last one was served, and serving it
/// costs `work` ms. Returns the step counts the transcript would have seen, one per width after the
/// first (the first width of a drag always starts a new one).
function drag({ widths, gap, work }: { widths: number; gap: number; work: number }): number[] {
  let clock: LiveResizeClock = { at: Number.NEGATIVE_INFINITY, steps: 0 };
  let now = 1000;
  const steps: number[] = [];
  for (let width = 0; width < widths; width += 1) {
    clock = stepLiveResize(clock, now);
    steps.push(clock.steps);
    // The step's own work, then the next width a frame later.
    clock = { ...clock, served: now + work };
    now += work + gap;
  }
  return steps;
}

describe("continuesLiveResize", () => {
  it("is false before any width has been served", () => {
    expect(continuesLiveResize({ at: 0, steps: 0 }, 1)).toBe(false);
  });

  it("continues a drag whose widths arrive promptly after the last was served", () => {
    expect(continuesLiveResize({ at: 0, steps: 1, served: 100 }, 116)).toBe(true);
  });

  it("does not continue after a quiet gap longer than the window", () => {
    expect(continuesLiveResize({ at: 0, steps: 1, served: 100 }, 100 + LIVE_RESIZE_MS + 1)).toBe(false);
  });

  it("continues a drag whose own frames cost longer than the window", () => {
    // The regression. A 290 ms pass puts the next width of the same drag 306 ms after this one
    // began, but only 16 ms after it was served. Read from the start of the step it was false, so
    // the transcript treated every frame of a long chat's drag as a fresh one-off resize: no flow,
    // and every row measured again (`flow.anchored` never happened at 100k rows, where the
    // observer's `flush.drawn` then cost 216 ms at p95).
    const began = 1000;
    const work = 290;
    const next = began + work + 16;
    expect(next - began).toBeGreaterThan(LIVE_RESIZE_MS);
    expect(continuesLiveResize({ at: began, steps: 1, served: began + work }, next)).toBe(true);
  });
});

describe("stepLiveResize", () => {
  it("counts up through a short chat's drag", () => {
    // 16 ms frames: every width continues the one before.
    expect(drag({ widths: 5, gap: 16, work: 4 })).toEqual([0, 1, 2, 3, 4]);
  });

  it("counts up through a long chat's drag, whose frames cost more than the window", () => {
    // The regression, as the transcript sees it: 300 ms of work a frame, the next width 16 ms after
    // each pass. Before the fix every step reset to 0, so `steps` never reached LIVE_FLOW_STEPS (2)
    // and the rows never flowed.
    const steps = drag({ widths: 5, gap: 16, work: 300 });
    expect(steps).toEqual([0, 1, 2, 3, 4]);
    expect(Math.max(...steps)).toBeGreaterThanOrEqual(2);
  });

  it("starts again for a genuine second resize after an idle gap", () => {
    // A cheap pass and then a long quiet: a window that was resized twice, not dragged.
    expect(drag({ widths: 3, gap: LIVE_RESIZE_MS + 50, work: 4 })).toEqual([0, 0, 0]);
  });

  it("keeps the step that began a drag at 0", () => {
    expect(stepLiveResize({ at: Number.NEGATIVE_INFINITY, steps: 0 }, 1).steps).toBe(0);
  });
});

describe("resumesLiveResize", () => {
  it("is false before any resize settled", () => {
    expect(resumesLiveResize({ at: 0, steps: 0 }, 1)).toBe(false);
  });

  it("takes a drag that paused on the divider up again", () => {
    // Leo's 2026-11-18 drag paused a few hundred ms at a time: past LIVE_RESIZE_MS, so it settled,
    // and its next width started over two steps from flow.
    expect(resumesLiveResize({ at: 0, steps: 0, settled: 1000 }, 1000 + 300)).toBe(true);
  });

  it("starts a new resize after a long quiet", () => {
    expect(resumesLiveResize({ at: 0, steps: 0, settled: 1000 }, 1000 + LIVE_RESUME_MS + 1)).toBe(false);
  });
});

describe("widthChanged", () => {
  // A new chat has no session and no layout yet: `undefined === undefined` read as the same chat and the
  // transcript's first render threw ("Cannot read properties of undefined (reading 'width')"), so a new
  // chat's pane showed "The agent pane could not be drawn." (cmuxterm-hq#15602, fleet step b3282f50).
  it("is false for a chat with no layout yet, session or not", () => {
    expect(widthChanged(undefined, undefined, 640)).toBe(false);
    expect(widthChanged(undefined, "s1", 640)).toBe(false);
  });

  it("is true for the same chat at another width or after a partial layout, false otherwise", () => {
    expect(widthChanged({ sessionId: "s1", width: 600 }, "s1", 640)).toBe(true);
    expect(widthChanged({ sessionId: "s1", width: 640, partial: true }, "s1", 640)).toBe(true);
    expect(widthChanged({ sessionId: "s1", width: 640 }, "s1", 640)).toBe(false);
    expect(widthChanged({ sessionId: "s0", width: 600 }, "s1", 640)).toBe(false);
  });
});
