// followChase.ts: a move of the followed rows is drawn back and chased home on the display's frames,
// within the speed limit, never past its rest, and the frame loop ends at rest. The live browser
// behaviour at 120 Hz is in test/send-stream-motion.test.ts.
import { expect, test } from "bun:test";
import { bezierAt } from "../../../ui/cubicBezier";
import { currentChatMetrics } from "../chatDisplay";
import {
  ARRIVAL_BURST_S,
  ARRIVAL_FRAME_LINES,
  arrivalStepMs,
  BURST_S,
  CHASE_HOLD_LINES,
  CHASE_LAND_LINES,
  CHASE_MAX_SPEED,
  chaseMaxTrail,
  createFollowChase,
} from "./followChase";
import type { FollowMotionArm } from "./followMotion.experiment";

/// A thread with a stand-in window whose frames the test runs one at a time (8.33 ms apart).
function fixture(motion: { off?: boolean; reduce?: boolean; token?: string; optOut?: boolean; look?: string } = {}) {
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
    closest: (selector: string) =>
      motion.optOut && selector.includes("follow-glide")
        ? {}
        : motion.look && selector.includes("data-tail-glide")
          ? { getAttribute: () => motion.look }
          : null,
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
  // A quiet frame within CHASE_LAND_LINES of home lands at once: nothing moves after the turn
  // settles (agent-pane-stream-jitter).
  chase.shift(node, -0.5 * line);
  chase.land();
  expect(drawn()).toBe(0);
  expect(pending()).toBe(0);
});

test("a turn that ends in a frame that already moved adds no snap: that frame moves at most a line", () => {
  // send-stream-motion: the reply's last line lands (part of it at once, as a landing frame does),
  // the turn ends in the same frame, and a snap of what was left moved the rows 26-40 px in it.
  const chase = createFollowChase("blocks");
  const { node, frame, drawn, pending } = fixture();
  const line = currentChatMetrics().lineHeight;
  chase.shift(node, -0.5 * line, 2 * line);
  frame();
  const before = drawn();
  // The rows' layout rises a line; the thread is drawn `drawn()` from it.
  chase.shift(node, -line, 2 * line);
  chase.land();
  expect(Math.abs(-line + drawn() - before)).toBeLessThanOrEqual(line + 1e-6);
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

test("blocks: what lands before a frame's step, the step and what lands after it move the rows at most a line", () => {
  // send-stream-motion.test.ts on the frames' own clock, frame 247 of the send: a 4-line block landed
  // between two frames (16 px of it at once), that frame's step moved 6 px, then the same frame's
  // measuring pass brought 0.9 of a line more and moved 12 px of it at once: 34.5 px, a line and a
  // half, in one 120 Hz frame. The step forgot what the frame had already moved at once.
  const chase = createFollowChase("blocks");
  const { node, frame, drawn } = fixture();
  const line = currentChatMetrics().lineHeight;
  chase.shift(node, -0.5 * line, 52);
  frame();
  frame();
  const before = drawn();
  chase.shift(node, -4 * line, 52);
  frame();
  chase.shift(node, -0.88 * line, 52);
  // The rows' move on screen in that frame: the layout's (up 4.88 lines) less what the thread is
  // drawn back by now, against where it was drawn in the frame before.
  const moved = -4.88 * line + (drawn() - before);
  expect(Math.abs(moved)).toBeLessThanOrEqual(line + 1e-6);
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

// Leo, 2026-11-07: "the jumps are jarring. We want to minimize the jumps", and 2026-11-09: "the
// animations end to end need to just resolve faster" (test/row-arrival-settle.test.ts).
test("a row that arrived holds all of its move back, then comes home on the arrival step, ending on its last frame", () => {
  const line = currentChatMetrics().lineHeight;
  for (const px of [28, 115]) {
    const chase = createFollowChase("blocks");
    const { node, frame, drawn } = fixture();
    chase.shift(node, -px, line * 10, false, true);
    expect(drawn()).toBeCloseTo(px);
    const steps = Math.ceil(arrivalStepMs(px) / (1000 / 120));
    let previous = drawn();
    let frames = 0;
    while (drawn() !== 0 && frames < 60) {
      frame();
      frames += 1;
      // No frame moves more than the step's bound, and none moves the rows away from home.
      expect(previous - drawn()).toBeLessThanOrEqual(ARRIVAL_FRAME_LINES * line + 1e-6);
      expect(drawn()).toBeLessThanOrEqual(previous);
      previous = drawn();
    }
    // Home at the step's end exactly, with no tail: a call's row (28 px) on the quick step (80 ms),
    // a steer and its call (115 px) over the frames its bound needs (110 ms).
    expect({ px, frames }).toEqual({ px, frames: steps });
    expect(px > 70 || steps <= 10).toBe(true);
    expect(steps).toBeLessThanOrEqual(14);
  }
});

test("a chase whose first frame comes long after it was asked for (a covered view) lands before that frame paints", () => {
  // #41252: one block arrives while another workspace covers the chat and nothing moves after it.
  // The page draws no frames for a second; the first one back must draw the rows home, not 79 px off.
  const line = currentChatMetrics().lineHeight;
  const real = performance.now.bind(performance);
  try {
    for (const arm of ["spring", "blocks", "chunk", "linear"] as FollowMotionArm[])
      for (const arrived of [false, true])
        for (const [lateMs, glides] of [
          [1000, false],
          // FRAMELESS_MS itself is a covered stretch: "150 ms or more".
          [150, false],
          [60, true],
        ] as const) {
          const chase = createFollowChase(arm);
          const { node, frame, drawn, pending } = fixture();
          let skew = 0;
          performance.now = () => real() + skew;
          chase.shift(node, -132, line * 10, false, arrived);
          expect(drawn()).toBeGreaterThan(0);
          skew = lateMs;
          frame();
          // Late past FRAMELESS_MS: home, the loop ended. A busy page's frame (60 ms) still glides.
          expect({ arm, arrived, lateMs, moving: drawn() > 0 }).toEqual({ arm, arrived, lateMs, moving: glides });
          if (!glides) expect(pending()).toBe(0);
          performance.now = real;
        }
  } finally {
    performance.now = real;
  }
});

test("a move that comes during an arrival's step keeps the step's end", () => {
  const line = currentChatMetrics().lineHeight;
  const chase = createFollowChase("blocks");
  const { node, frame, drawn } = fixture();
  chase.shift(node, -28, line * 10, false, true);
  for (let index = 0; index < 4; index += 1) frame();
  // The arrived row's measured height a pass later: 6 px more, four frames in.
  chase.shift(node, -6, line * 10, false, true);
  let frames = 4;
  while (drawn() !== 0 && frames < 60) {
    frame();
    frames += 1;
  }
  expect(frames).toBe(Math.ceil(arrivalStepMs(28) / (1000 / 120)));
});

// The earlier looks (data-tail-glide quick, glide, jump: the gallery's comparisons) keep the spring.
test("in the earlier looks a row that arrived holds all of its move back, and is back within the bound in ARRIVAL_BURST_S", () => {
  const chase = createFollowChase("blocks");
  const { node, frame, drawn } = fixture({ look: "quick" });
  const line = currentChatMetrics().lineHeight;
  // A steer and the call it came under: 115 px of rows above the live line. A reply's growth of the
  // same size moves CHASE_LAND_LINES of it at once; an arrival moves none of it in that frame.
  chase.shift(node, -115, line * 10, false, true);
  expect(drawn()).toBeCloseTo(115);
  let previous = drawn();
  let frames = 0;
  while (drawn() > chaseMaxTrail() + 0.5) {
    frame();
    frames += 1;
    // Never more than a line in a frame.
    expect(previous - drawn()).toBeLessThanOrEqual(line + 1e-6);
    previous = drawn();
  }
  // Back within the bound over ARRIVAL_BURST_S (nine 120 Hz frames), not BURST_S's six.
  expect(frames).toBeLessThanOrEqual(Math.ceil(ARRIVAL_BURST_S * 120) + 1);
  expect(frames).toBeGreaterThan(Math.ceil(BURST_S * 120));
  // The same move as a reply's growth lands part at once, as before.
  const growth = createFollowChase("blocks");
  const other = fixture();
  growth.shift(other.node, -2 * line, line * 10);
  expect(other.drawn()).toBeCloseTo((2 - Math.min(2 - CHASE_HOLD_LINES, CHASE_LAND_LINES)) * line);
});

test("the reply draining while the turn's end fold plays: each frame of the two together keeps to the fold's bound", () => {
  // turn-transition-jumps `thought-text` end: the fold's first frame (11.5 px of a 43 px fold on the
  // settle) and the drain chase's (3.8 px of the reply's last line) moved the rows 15.3 px in one
  // frame, each within its own bound.
  const chase = createFollowChase("blocks");
  const { node, frame, drawn, pending } = fixture();
  const line = currentChatMetrics().lineHeight;
  const clock = node.ownerDocument.timeline as unknown as { currentTime: number };
  const start = clock.currentTime;
  const span = 43;
  const easing = "cubic-bezier(0.16, 1, 0.3, 1)";
  const duration = 180;
  const fold = {
    playState: "running",
    startTime: start,
    effect: {
      getKeyframes: () => [{ translate: `0px ${span}px` }, { translate: "0px 0px" }],
      getTiming: () => ({ easing }),
      getComputedTiming: () => ({ duration, delay: 0, localTime: clock.currentTime - start }),
    },
  } as unknown as Animation;
  const curve = [0.16, 1, 0.3, 1] as const;
  const foldAt = (time: number) => span * (1 - bezierAt(curve, Math.min(1, Math.max(0, (time - start) / duration))));
  chase.alongside(new Set([fold]));
  chase.shift(node, -line, Number.POSITIVE_INFINITY);
  chase.land();
  let previous = drawn();
  let folded = foldAt(clock.currentTime);
  let frames = 0;
  while (pending() > 0 && frames < 240) {
    const at = frame();
    const foldNow = foldAt(clock.currentTime);
    frames += 1;
    expect(previous - at + (folded - foldNow)).toBeLessThanOrEqual(ARRIVAL_FRAME_LINES * line + 1e-6);
    previous = at;
    folded = foldNow;
  }
  expect(drawn()).toBe(0);
  // Still home soon after the fold's fast first frames: within a few frames of BURST_S.
  expect(frames).toBeLessThanOrEqual(Math.ceil(BURST_S * 120) + 4);
});

test("carry: another motion's part the reader froze is drawn by the chase, held there, and goes home when followed again", () => {
  const chase = createFollowChase("blocks");
  const { node, frame, drawn, pending } = fixture();
  // The composer growth's rise drew the rows 14 px down when the reader's wheel came.
  chase.carry(node, 14);
  chase.hold();
  expect(drawn()).toBeCloseTo(14);
  expect(pending()).toBe(0);
  frame();
  frame();
  // Held: nothing moves but the reader's own scroll.
  expect(drawn()).toBeCloseTo(14);
  expect(chase.outstanding()).toBeCloseTo(14);
  // Followed again: home from where it was painted, never past it.
  chase.resume();
  let previous = drawn();
  while (pending() > 0) {
    const at = frame();
    expect(at).toBeLessThanOrEqual(previous + 1e-9);
    expect(at).toBeGreaterThanOrEqual(0);
    previous = at;
  }
  expect(drawn()).toBe(0);
  // Nothing to carry moves nothing.
  chase.carry(node, 0);
  expect(drawn()).toBe(0);
});

/// Runs a carried offset home after `resume`: every frame drawn, until the loop ends (at most 600).
function carriedHome(arm: FollowMotionArm, px: number) {
  const chase = createFollowChase(arm);
  const { node, frame, drawn, pending } = fixture();
  chase.carry(node, px);
  chase.hold();
  frame();
  expect(drawn()).toBeCloseTo(px);
  chase.resume();
  const frames: number[] = [];
  while (pending() > 0 && frames.length < 600) frames.push(frame());
  return { frames, drawn: drawn(), outstanding: chase.outstanding(), pending: pending() };
}

test("carry in the `eased` arm: what the reader froze springs home when followed again, as in the default arm (#41478 F1)", () => {
  // The eased arm chases nothing of its own, but the composer growth's rise it froze is held on the
  // chase. Followed again it goes home on the default arm's spring, frame for frame, and rests at 0.
  const eased = carriedHome("eased", 40);
  const blocks = carriedHome("blocks", 40);
  expect(eased.drawn).toBe(0);
  expect(eased.outstanding).toBe(0);
  expect(eased.pending).toBe(0);
  expect(eased.frames.length).toBe(blocks.frames.length);
  for (const [index, at] of eased.frames.entries()) expect(at).toBeCloseTo(blocks.frames[index]!, 6);
  // Never past home, never back up.
  let previous = 40;
  for (const at of eased.frames) {
    expect(at).toBeLessThanOrEqual(previous + 1e-9);
    expect(at).toBeGreaterThanOrEqual(0);
    previous = at;
  }
});

test("carry in the `instant` arm: what the reader froze lands in the first frame it goes home in (#41478 F2)", () => {
  // Every move in this arm lands in the frame it happens: no animation of the carried rise.
  const instant = carriedHome("instant", 40);
  expect(instant.frames).toEqual([0]);
  expect(instant.drawn).toBe(0);
  expect(instant.outstanding).toBe(0);
  expect(instant.pending).toBe(0);
});
