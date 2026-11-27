// Ordering map O2 (design/chat-animation-ordering-map.md): a next call arrives while the arrival step
// of the last one plays. Leo, 2026-11-21: "some animations i think are still a bit... off. like, you
// finish some sort of tool call, things happen, things fold, stuff comes in at different times".
// followChase.ts keeps the step's end (`left`) when a move joins; the remainder must still move no
// more than a frame's bound per frame, and the rows must be home when the first step would have ended
// or soon after, never in one frame (B2.3: "a 20 px move plays in max(2 ms, frames*8.3 ms)").
import { expect, test } from "bun:test";
import { currentChatMetrics } from "../chatDisplay";
import { ARRIVAL_FRAME_LINES, arrivalStepMs, createFollowChase } from "./followChase";

/// Same fixture as followChase.test.ts: a thread whose frames the test runs one at a time (8.33 ms).
function fixture() {
  let callbacks = new Map<number, FrameRequestCallback>();
  let id = 0;
  let now = 1000;
  const view = {
    matchMedia: () => ({ matches: false }),
    getComputedStyle: () => ({ getPropertyValue: () => "" }),
    requestAnimationFrame: (callback: FrameRequestCallback) => {
      callbacks.set(++id, callback);
      return id;
    },
    cancelAnimationFrame: (handle: number) => callbacks.delete(handle),
  };
  const doc = {
    documentElement: { dataset: {} },
    defaultView: view,
    visibilityState: "visible",
    timeline: {
      get currentTime() {
        return now;
      },
    },
  };
  const node = {
    ownerDocument: doc,
    parentElement: { parentElement: { clientHeight: 600 } },
    closest: () => null,
    style: {
      setProperty() {},
      removeProperty(name: string) {
        if (name === "translate") delete (node.style as unknown as Record<string, unknown>).translate;
      },
    } as unknown as CSSStyleDeclaration,
  };
  const drawn = () =>
    Number.parseFloat(
      String((node.style as unknown as { translate?: string }).translate ?? "0 0").split(" ")[1] ?? "0",
    ) || 0;
  const frame = () => {
    now += 1000 / 120;
    const due = callbacks;
    callbacks = new Map();
    for (const callback of due.values()) callback(now);
    return drawn();
  };
  return { node: node as unknown as HTMLElement, frame, drawn, pending: () => callbacks.size };
}

/// The next arrival `at` frames into the first one's step; returns the most one frame moved the rows
/// after it, and the frames the whole move took.
function second(first: number, next: number, at: number) {
  const line = currentChatMetrics().lineHeight;
  const chase = createFollowChase("blocks");
  const { node, frame, drawn } = fixture();
  chase.shift(node, -first, line * 10, false, true);
  for (let index = 0; index < at; index += 1) frame();
  chase.shift(node, -next, line * 10, false, true);
  let previous = drawn();
  let worst = 0;
  let frames = at;
  while (drawn() !== 0 && frames < 120) {
    const now = frame();
    frames += 1;
    worst = Math.max(worst, previous - now);
    previous = now;
  }
  return { worst, frames, line, ended: drawn() === 0 };
}

test("O2: a call arriving while the last one's step plays goes home on its end, within a line's bound a frame", () => {
  const steps = Math.ceil(arrivalStepMs(28) / (1000 / 120));
  for (const at of [1, 4, steps - 3]) {
    const { worst, frames, line, ended } = second(28, 28, at);
    expect(ended).toBe(true);
    expect(worst).toBeLessThanOrEqual(ARRIVAL_FRAME_LINES * line + 1e-6);
    // Home no later than a step after the second arrival, and not before the first step's end.
    expect(frames).toBeGreaterThanOrEqual(steps);
    expect(frames).toBeLessThanOrEqual(at + Math.ceil(arrivalStepMs(56) / (1000 / 120)));
  }
});

// B2.3 feared that `arrivalStepMs(x, scale, left)` floors the second move at the time left, so 20 px
// more play in about two frames. Measured: the move stays under the bound at every late arrival.
test("O2: a call arriving as the step ends (1 to 3 frames left) still moves under the frame bound", () => {
  const steps = Math.ceil(arrivalStepMs(28) / (1000 / 120));
  for (const next of [20, 40, 80])
    for (const left of [1, 2, 3]) {
      const { worst, line, ended } = second(28, next, steps - left);
      expect({ next, left, ended }).toEqual({ next, left, ended: true });
      expect({ next, left, ok: worst <= ARRIVAL_FRAME_LINES * line + 1e-6 }).toEqual({ next, left, ok: true });
    }
});
