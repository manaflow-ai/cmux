import { describe, expect, test } from "bun:test";
import { createDrawPacer, DRAW_FREE_MS, DRAW_MAX_WAIT_MS, type DrawPacerEnv } from "./drawPacer";

const FRAME_MS = 16;

/** A manual clock, a frame queue and an after-task queue, run by the test. */
function fakeEnv() {
  let time = 0;
  let pending = false;
  let frames: (() => void)[] = [];
  let tasks: (() => void)[] = [];
  let cancelled = 0;
  const env: DrawPacerEnv = {
    now: () => time,
    frame: (run) => {
      frames.push(run);
      return () => {
        cancelled += 1;
        frames = frames.filter((f) => f !== run);
      };
    },
    inputPending: () => pending,
    afterTask: (cb) => tasks.push(cb),
  };
  return {
    env,
    get now() {
      return time;
    },
    advance(ms: number) {
      time += ms;
    },
    setInput(value: boolean) {
      pending = value;
    },
    pendingFrames: () => frames.length,
    cancelled: () => cancelled,
    /** One display frame: the clock moves to the next frame, its callbacks run, then the task after them. */
    frame() {
      time = Math.ceil((time + 0.001) / FRAME_MS) * FRAME_MS;
      const run = frames;
      frames = [];
      for (const cb of run) cb();
      const after = tasks;
      tasks = [];
      for (const cb of after) cb();
    },
  };
}

/** A draw that costs `ms` of the main thread (its run and what it triggers before the next task). */
function draw(env: ReturnType<typeof fakeEnv>, ms: number, drawn: number[]) {
  return () => {
    drawn.push(env.now);
    env.advance(ms);
  };
}

describe("draw pacer", () => {
  test("cheap draws run in the next frame, paced or not, and never wait for input", () => {
    const env = fakeEnv();
    const pacer = createDrawPacer(env.env);
    const drawn: number[] = [];
    env.setInput(true);
    for (let i = 0; i < 5; i += 1) {
      pacer.schedule(draw(env, 2, drawn), true);
      env.frame();
    }
    expect(drawn.length).toBe(5);
    expect(pacer.stats().paced_waits).toBe(0);
    expect(pacer.stats().input_waits).toBe(0);
  });

  test("after an expensive draw a paced draw waits until the thread was free as long as it took", () => {
    const env = fakeEnv();
    const pacer = createDrawPacer(env.env);
    const drawn: number[] = [];
    pacer.schedule(draw(env, 30, drawn), true);
    env.frame();
    const firstEnd = env.now;
    pacer.schedule(draw(env, 30, drawn), true);
    // Frames before the free point skip the draw.
    while (drawn.length < 2) env.frame();
    expect(drawn[1]! - firstEnd).toBeGreaterThanOrEqual(30);
    expect(pacer.stats().paced_waits).toBeGreaterThan(0);
  });

  test("an unpaced draw (the person's change) runs in the next frame even after an expensive draw", () => {
    const env = fakeEnv();
    const pacer = createDrawPacer(env.env);
    const drawn: number[] = [];
    pacer.schedule(draw(env, 40, drawn), true);
    env.frame();
    env.setInput(true);
    pacer.schedule(draw(env, 40, drawn), false);
    env.frame();
    expect(drawn.length).toBe(2);
  });

  test("a pending key defers an expensive paced draw by one frame, not more", () => {
    const env = fakeEnv();
    const pacer = createDrawPacer(env.env);
    const drawn: number[] = [];
    pacer.schedule(draw(env, DRAW_FREE_MS + 1, drawn), true);
    env.frame();
    // Past the free point: only the key holds it now.
    env.advance(4 * FRAME_MS);
    env.setInput(true);
    pacer.schedule(draw(env, DRAW_FREE_MS + 1, drawn), true);
    env.frame();
    expect(drawn.length).toBe(1);
    expect(pacer.stats().input_waits).toBe(1);
    env.frame();
    expect(drawn.length).toBe(2);
  });

  test("anti-starvation: a paced draw runs by DRAW_MAX_WAIT_MS however expensive draws are", () => {
    const env = fakeEnv();
    const pacer = createDrawPacer(env.env);
    const drawn: number[] = [];
    pacer.schedule(draw(env, 500, drawn), true);
    env.frame();
    env.setInput(true);
    const asked = env.now;
    pacer.schedule(draw(env, 500, drawn), true);
    for (let i = 0; i < 20 && drawn.length < 2; i += 1) env.frame();
    expect(drawn.length).toBe(2);
    expect(drawn[1]! - asked).toBeLessThanOrEqual(DRAW_MAX_WAIT_MS + FRAME_MS);
    expect(pacer.stats().starved_runs).toBe(1);
  });

  test("cancel stops a waiting draw and leaves no frame asked for (stop condition)", () => {
    const env = fakeEnv();
    const pacer = createDrawPacer(env.env);
    const drawn: number[] = [];
    pacer.schedule(draw(env, 30, drawn), true);
    env.frame();
    const cancel = pacer.schedule(draw(env, 30, drawn), true);
    env.frame();
    expect(drawn.length).toBe(1);
    expect(env.pendingFrames()).toBe(1);
    cancel();
    expect(env.pendingFrames()).toBe(0);
    for (let i = 0; i < 10; i += 1) env.frame();
    expect(drawn.length).toBe(1);
  });

  test("with nothing scheduled it asks for no frame", () => {
    const env = fakeEnv();
    const pacer = createDrawPacer(env.env);
    const drawn: number[] = [];
    pacer.schedule(draw(env, 30, drawn), true);
    env.frame();
    env.frame();
    expect(env.pendingFrames()).toBe(0);
  });
});
