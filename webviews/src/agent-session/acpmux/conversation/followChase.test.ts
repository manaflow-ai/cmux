// followChase.ts: a move of the followed rows is drawn back and chased home on the display's frames,
// within the speed limit, never past its rest, and the frame loop ends at rest. The live browser
// behaviour at 120 Hz is in test/send-stream-motion.test.ts.
import { expect, test } from "bun:test";
import { currentChatMetrics } from "../chatDisplay";
import {
  BURST_S,
  CHASE_HOLD_LINES,
  CHASE_LAND_LINES,
  CHASE_MAX_SPEED,
  chaseMaxTrail,
  createFollowChase,
} from "./followChase";
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
    const line = currentChatMetrics().lineHeight;
    expect(chaseMaxTrail()).toBeCloseTo(2 * line);
    expect(chase.shift(node, -132)).toBe(true);
    // The rows stay where the reader saw them in the frame the move happened.
    expect(drawn()).toBeCloseTo(132);
    let previous = drawn();
    let frames = 0;
    let overFrames = 0;
    while (pending() > 0 && frames < 240) {
      const at = frame();
      frames += 1;
      if (at > chaseMaxTrail() + 1e-6) overFrames += 1;
      // Never away from its rest, never past it, never more than a line in a frame.
      expect(at).toBeLessThanOrEqual(previous + 1e-9);
      expect(at).toBeGreaterThanOrEqual(0);
      expect(previous - at).toBeLessThanOrEqual(line + 1e-6);
      previous = at;
    }
    // Past the trail bound it is back within it in six 120 Hz frames (BURST_S), except the
    // fixed-duration arm, which keeps its own 180 ms curve.
    if (arm !== "chunk") expect(overFrames).toBeLessThanOrEqual(Math.ceil(BURST_S * 120));
    expect(pending()).toBe(0);
    expect(drawn()).toBe(0);
    expect(chase.outstanding()).toBe(0);
    // Home within 400 ms (the burst, then two lines at the speed limit and the spring's settle).
    expect(frames).toBeLessThanOrEqual(48);
  },
);

test("near home the chase keeps to its speed limit", () => {
  const chase = createFollowChase("spring");
  const { node, frame, drawn, pending } = fixture();
  const line = currentChatMetrics().lineHeight;
  chase.shift(node, -chaseMaxTrail());
  let previous = drawn();
  while (pending() > 0) {
    const at = frame();
    // Within the bound: the limit and what it trails past a line over 150 ms.
    expect(previous - at).toBeLessThanOrEqual((CHASE_MAX_SPEED + Math.max(0, previous - line) / 0.15) / 120 + 1e-6);
    previous = at;
  }
});

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

test("a stream of lines and blocks: no frame moves more than a line, and the trail comes back within BURST_S", () => {
  const chase = createFollowChase("blocks");
  const { node, frame, drawn } = fixture();
  const line = currentChatMetrics().lineHeight;
  let over = 0;
  for (let index = 0; index < 60; index += 1) {
    // A line every frame, and a 96 px block every 15th.
    chase.shift(node, index % 15 === 14 ? -96 : -line / 4, Number.POSITIVE_INFINITY);
    const before = drawn();
    const at = frame();
    expect(before - at).toBeLessThanOrEqual(line + 1e-6);
    over = at > chaseMaxTrail() + 1e-6 ? over + 1 : 0;
    expect(over).toBeLessThanOrEqual(Math.ceil(BURST_S * 120));
  }
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

test("the reader's input holds the chase where it is drawn, and following again resumes it home", () => {
  const chase = createFollowChase("blocks");
  const { node, frame, drawn, pending } = fixture();
  chase.shift(node, -40);
  frame();
  const held = drawn();
  expect(held).toBeGreaterThan(0);
  chase.hold();
  // Nothing moves while held: no frame is asked for, and the thread stays drawn where it was.
  expect(pending()).toBe(0);
  frame();
  expect(drawn()).toBe(held);
  expect(chase.outstanding()).toBe(held);
  chase.resume();
  let frames = 0;
  while (pending() > 0 && frames < 240) {
    frame();
    frames += 1;
  }
  expect(drawn()).toBe(0);
});

test("the turn ending lands the chase within BURST_S, no frame more than a line", () => {
  const chase = createFollowChase("blocks");
  const { node, frame, drawn, pending } = fixture();
  const line = currentChatMetrics().lineHeight;
  chase.shift(node, -1.8 * line);
  chase.land();
  let previous = drawn();
  let frames = 0;
  while (pending() > 0 && frames < 240) {
    const at = frame();
    frames += 1;
    expect(previous - at).toBeLessThanOrEqual(line + 1e-6);
    previous = at;
  }
  expect(drawn()).toBe(0);
  expect(frames).toBeLessThanOrEqual(Math.ceil(BURST_S * 120) + 1);
  // Within a line of home it lands at once.
  chase.shift(node, -0.5 * line);
  chase.land();
  expect(drawn()).toBe(0);
  expect(pending()).toBe(0);
});

test("blocks: a reply's growth holds back a line; its landing frame moves the rest, up to CHASE_LAND_LINES", () => {
  const chase = createFollowChase("blocks");
  const { node, frame, drawn } = fixture();
  const line = currentChatMetrics().lineHeight;
  // A line of growth is held whole: the rows stay where the reader saw them.
  chase.shift(node, -line, 30);
  expect(drawn()).toBeCloseTo(CHASE_HOLD_LINES * line);
  while (drawn() > 0) frame();
  // A 1.5-line block: the part past a line moves at once, and that frame's step keeps the frame's
  // move within CHASE_LAND_LINES (the whole block drawn back pushed the live line under it down by
  // the block, and up again).
  chase.shift(node, -1.5 * line, 30);
  const landed = drawn();
  expect(landed).toBeCloseTo(CHASE_HOLD_LINES * line);
  expect(1.5 * line - frame()).toBeLessThanOrEqual(CHASE_LAND_LINES * line + 1e-6);
  // A send's rise (`below` unbounded) is drawn back whole, as before.
  chase.stop();
  chase.shift(node, -1.5 * line);
  expect(drawn()).toBeCloseTo(1.5 * line);
});

test("reader input while still followed (at the bottom, nothing scrolls) resumes the chase next frame", () => {
  const chase = createFollowChase("blocks");
  const { node, frame, drawn, pending } = fixture();
  chase.shift(node, -40);
  frame();
  expect(drawn()).toBeGreaterThan(0);
  // A wheel or key at the bottom: follow stays on and no later layout pass comes. The thread must
  // not stay drawn away from its layout with no frame loop to bring it home.
  chase.hold(() => true);
  let frames = 0;
  while (pending() > 0 && frames < 240) {
    frame();
    frames += 1;
  }
  expect(drawn()).toBe(0);
  expect(chase.outstanding()).toBe(0);
  expect(pending()).toBe(0);
});

test("reader input that parks the view keeps the chase held; a hold with nothing drawn clears at once", () => {
  const chase = createFollowChase("blocks");
  const { node, frame, drawn, pending } = fixture();
  chase.shift(node, -40);
  frame();
  const held = drawn();
  let following = true;
  chase.hold(() => following);
  // The scroll event that follows the input parks the reader before the next frame.
  following = false;
  frame();
  expect(pending()).toBe(0);
  expect(drawn()).toBe(held);
  // Held at rest: nothing is drawn and nothing is asked for.
  chase.stop();
  chase.hold(() => true);
  expect(drawn()).toBe(0);
  expect(pending()).toBe(0);
});

test.each(["spring", "chunk", "linear", "blocks"] as FollowMotionArm[])(
  "%s: a finite `below` after a send's rise is honoured",
  (arm) => {
    const chase = createFollowChase(arm);
    const { node, frame, drawn } = fixture();
    const line = currentChatMetrics().lineHeight;
    // A send: the rows rise out from behind the composer (`below` unbounded).
    chase.shift(node, -1.5 * line);
    frame();
    expect(drawn()).toBeGreaterThan(10);
    // Streamed growth with 10 px under the bottom stack (the `blocks` arm keeps to it once Jump to
    // latest held it; otherwise it may pass under the glass composer, by design).
    const held = arm === "blocks";
    chase.shift(node, -line, 10, held);
    expect(drawn()).toBeLessThanOrEqual(10 + 1e-6);
    // `fit` tightens it as well.
    chase.fit(4);
    expect(drawn()).toBeLessThanOrEqual(4 + 1e-6);
  },
);
