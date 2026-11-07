// followChase.ts: a move of the followed rows is drawn back and chased home on the display's frames,
// within the speed limit, never past its rest, and the frame loop ends at rest. The live browser
// behaviour at 120 Hz is in test/send-stream-motion.test.ts.
import { expect, test } from "bun:test";
import { CHASE_MAX_SPEED, createFollowChase } from "./followChase";
import type { FollowMotionArm } from "./followMotion.experiment";

/// A thread with a stand-in window whose frames the test runs one at a time (8.33 ms apart).
function fixture(motion: { off?: boolean; reduce?: boolean; token?: string; optOut?: boolean } = {}) {
  let callbacks = new Map<number, FrameRequestCallback>();
  let id = 0;
  let now = 1000;
  const style: Record<string, string> = {};
  const root = { dataset: motion.off ? { agentMotion: "off" } : ({} as Record<string, string>) };
  const view = {
    matchMedia: (query: string) => ({ matches: Boolean(motion.reduce) && query.includes("reduce") }),
    getComputedStyle: () => ({
      getPropertyValue: (name: string) => (name === "--agent-motion-move" ? (motion.token ?? "") : ""),
    }),
    requestAnimationFrame: (callback: FrameRequestCallback) => {
      callbacks.set(++id, callback);
      return id;
    },
    cancelAnimationFrame: (handle: number) => callbacks.delete(handle),
  };
  const doc = {
    documentElement: root,
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
    closest: (selector: string) => (motion.optOut && selector.includes("follow-glide") ? {} : null),
    style: {
      ...style,
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

test.each(["spring", "blocks", "chunk", "linear"] as FollowMotionArm[])(
  "%s: a 132 px rise is drawn back, chased home within the speed limit, and the loop ends at rest",
  (arm) => {
    const chase = createFollowChase(arm);
    const { node, frame, drawn, pending } = fixture();
    expect(chase.shift(node, -132)).toBe(true);
    // The rows stay where the reader saw them in the frame the move happened.
    expect(drawn()).toBeCloseTo(132);
    let previous = drawn();
    let frames = 0;
    while (pending() > 0 && frames < 240) {
      const at = frame();
      frames += 1;
      // Never away from its rest, never past it.
      expect(at).toBeLessThanOrEqual(previous + 1e-9);
      expect(at).toBeGreaterThanOrEqual(0);
      // The catch-up past two lines behind allows more than the limit, never more than a 120 Hz
      // frame of (limit + what it trails past two lines over 150 ms). The fixed-duration arm keeps
      // its own curve instead.
      if (arm !== "chunk")
        expect(previous - at).toBeLessThanOrEqual((CHASE_MAX_SPEED + Math.max(0, previous - 46) / 0.15) / 120 + 1e-6);
      previous = at;
    }
    expect(pending()).toBe(0);
    expect(drawn()).toBe(0);
    expect(chase.outstanding()).toBe(0);
    // Home within 400 ms (a 132 px send at the chase's speed limit and its spring's settle).
    expect(frames).toBeLessThanOrEqual(48);
  },
);

test("spring: a move while one plays continues from where the thread is drawn and at its speed", () => {
  const chase = createFollowChase("spring");
  const { node, frame, drawn } = fixture();
  chase.shift(node, -22.75);
  for (let index = 0; index < 4; index += 1) frame();
  const before = drawn();
  const step = before - frame();
  // The next line lands: the drawn rows do not move in that frame, and the next step is no slower.
  chase.shift(node, -22.75);
  expect(drawn()).toBeCloseTo(before - step + 22.75);
  const at = drawn();
  expect(at - frame()).toBeGreaterThanOrEqual(step - 1e-6);
});

test("motion off, Reduce Motion, a zero move token, the opt-out and the instant arm move at once", () => {
  for (const motion of [{ off: true }, { reduce: true }, { token: "0ms" }, { optOut: true }]) {
    const chase = createFollowChase("spring");
    const { node, drawn, pending } = fixture(motion);
    expect(chase.shift(node, -40)).toBe(false);
    expect(drawn()).toBe(0);
    expect(pending()).toBe(0);
  }
  const { node, drawn } = fixture();
  expect(createFollowChase("instant").shift(node, -40)).toBe(false);
  expect(drawn()).toBe(0);
});

test("stop rests the thread where it lays out and ends the frame loop", () => {
  const chase = createFollowChase("spring");
  const { node, frame, drawn, pending } = fixture();
  chase.shift(node, -60);
  frame();
  chase.stop();
  expect(drawn()).toBe(0);
  expect(pending()).toBe(0);
});
