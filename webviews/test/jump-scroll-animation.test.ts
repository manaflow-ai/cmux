// l10n-allow-file: deterministic scroll-motion fixtures.
import { expect, test } from "bun:test";
import { animateScroll, stopScroll } from "../src/agent-session/acpmux/threadMinimap/scrollMotion";
import { JUMP_CURVE, jumpGlideStart } from "../src/agent-session/acpmux/threadMinimap/model";

function frames() {
  const saved = [globalThis.requestAnimationFrame, globalThis.cancelAnimationFrame] as const;
  const pending = new Map<number, FrameRequestCallback>();
  let handle = 0;
  globalThis.requestAnimationFrame = (run) => {
    pending.set(++handle, run);
    return handle;
  };
  globalThis.cancelAnimationFrame = (id) => void pending.delete(id);
  class Scroller extends EventTarget {
    private top = 0;
    get scrollTop() {
      return this.top;
    }
    // Whole-pixel WebKit scrollTop must still arrive, without exponential stalling.
    set scrollTop(value: number) {
      this.top = Math.round(value);
    }
  }
  const node = new Scroller() as unknown as HTMLElement;
  return {
    node,
    pending,
    tick(now: number) {
      const current = [...pending.values()];
      pending.clear();
      for (const run of current) run(now);
    },
    restore() {
      stopScroll(node);
      [globalThis.requestAnimationFrame, globalThis.cancelAnimationFrame] = saved;
    },
  };
}

test("one clock follows a moving target and lands exactly with rounded offsets", () => {
  const clock = frames();
  let target = 900;
  let landed = 0;
  let cancelled = 0;
  const start = performance.now();
  try {
    animateScroll(
      clock.node,
      () => target,
      400,
      JUMP_CURVE,
      () => landed++,
      () => cancelled++,
    );
    const tops: number[] = [];
    for (let at = 0; at <= 400; at += 20) {
      target += 5;
      clock.tick(start + at + 1);
      tops.push(clock.node.scrollTop);
    }
    expect(tops.slice(1).every((top, at) => top >= tops[at]!)).toBe(true);
    expect(clock.node.scrollTop).toBe(target);
    expect(landed).toBe(1);
    expect(cancelled).toBe(0);
    expect(clock.pending.size).toBe(0);
  } finally {
    clock.restore();
  }
});

test.each(["wheel", "pointerdown", "touchstart", "keydown"])("%s cancels with no later landing", (input) => {
  const clock = frames();
  let landed = 0;
  try {
    animateScroll(
      clock.node,
      () => 900,
      400,
      JUMP_CURVE,
      () => landed++,
    );
    clock.tick(performance.now() + 100);
    const stopped = clock.node.scrollTop;
    clock.node.dispatchEvent(new Event(input));
    clock.tick(performance.now() + 800);
    expect(clock.node.scrollTop).toBe(stopped);
    expect(clock.pending.size).toBe(0);
    expect(landed).toBe(0);
  } finally {
    clock.restore();
  }
});

test("zero motion lands synchronously; lifecycle stop cancels the pending frame", () => {
  const clock = frames();
  try {
    animateScroll(clock.node, () => 901, 0, JUMP_CURVE);
    expect(clock.node.scrollTop).toBe(901);
    expect(clock.pending.size).toBe(0);
    animateScroll(clock.node, () => 1400, 400, JUMP_CURVE);
    stopScroll(clock.node);
    expect(clock.pending.size).toBe(0);
    clock.tick(performance.now() + 800);
    expect(clock.node.scrollTop).toBe(901);
  } finally {
    clock.restore();
  }
});

test("a replacement notifies the old owner without reporting a completed landing", () => {
  const clock = frames();
  let cancelled = 0;
  let landed = 0;
  try {
    animateScroll(
      clock.node,
      () => 900,
      400,
      JUMP_CURVE,
      () => landed++,
      () => cancelled++,
    );
    clock.tick(performance.now() + 100);
    animateScroll(clock.node, () => 100, 200, JUMP_CURVE);
    expect(cancelled).toBe(1);
    expect(landed).toBe(0);
    clock.tick(performance.now() + 800);
    expect(clock.node.scrollTop).toBe(100);
    expect(cancelled).toBe(1);
    expect(landed).toBe(0);
  } finally {
    clock.restore();
  }
});

test("a long Jump to latest skips the middle and glides only the last viewport", () => {
  // Within a viewport of the end: the whole way glides.
  expect(jumpGlideStart(500, 1_000, 600)).toBe(500);
  expect(jumpGlideStart(400, 1_000, 600)).toBe(400);
  // Farther: it starts one viewport above the end, so the rows in between never mount.
  expect(jumpGlideStart(0, 50_000, 600)).toBe(49_400);
  // Already at or below the end: nothing to skip.
  expect(jumpGlideStart(1_000, 1_000, 600)).toBe(1_000);
  expect(jumpGlideStart(1_200, 1_000, 600)).toBe(1_200);
});
