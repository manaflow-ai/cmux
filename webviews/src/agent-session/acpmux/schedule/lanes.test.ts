import { describe, expect, test } from "bun:test";
import { createLanes, FRAME_BUDGET_MS, INPUT_QUIET_MS, NO_FRAME_MS, SLICE_MS, type LanesEnv } from "./lanes";

/** A fake engine: a manual clock, a rAF queue, a task queue and timers, all run by the test. */
function fakeEngine(options: { engineInputPending?: () => boolean } = {}) {
  let time = 0;
  let hidden = false;
  let frames: (() => void)[] = [];
  const tasks: { cb: () => void; priority: string }[] = [];
  const timers: { at: number; cb: () => void; live: boolean }[] = [];
  const listeners = new Map<string, Set<() => void>>();
  const errors: unknown[] = [];
  const env: LanesEnv = {
    now: () => time,
    requestFrame: (cb) => frames.push(cb),
    postTask: (cb, priority) => tasks.push({ cb, priority }),
    setTimer: (cb, ms) => {
      const timer = { at: time + ms, cb, live: true };
      timers.push(timer);
      return () => {
        timer.live = false;
      };
    },
    engineInputPending: options.engineInputPending,
    hidden: () => hidden,
    listen: (type, cb) => {
      const set = listeners.get(type) ?? new Set();
      set.add(cb);
      listeners.set(type, set);
      return () => set.delete(cb);
    },
    reportError: (error) => errors.push(error),
  };
  const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
  return {
    env,
    errors,
    listeners,
    advance(ms: number) {
      time += ms;
    },
    get now() {
      return time;
    },
    pendingFrames: () => frames.length,
    pendingTasks: () => tasks.length,
    liveTimers: () => timers.filter((t) => t.live).length,
    /** Runs the requested frame callbacks, then lets their microtasks finish. */
    async frame() {
      const run = frames;
      frames = [];
      for (const cb of run) cb();
      await settle();
    },
    /** Runs every queued task, and the ones they post, until none is left (bounded). */
    async tasks(limit = 100) {
      for (let i = 0; i < limit && tasks.length; i++) {
        tasks.shift()!.cb();
        await settle();
      }
    },
    /** Moves the clock to the next live timer and fires it. */
    async timer() {
      const next = timers.filter((t) => t.live).sort((a, b) => a.at - b.at)[0];
      if (!next) return;
      time = Math.max(time, next.at);
      next.live = false;
      next.cb();
      await settle();
    },
    fire(type: string) {
      for (const cb of listeners.get(type) ?? []) cb();
    },
    setHidden(value: boolean) {
      hidden = value;
      this.fire("visibilitychange");
    },
  };
}

describe("frame lane", () => {
  test("runs once per frame and coalesces by key, latest fn wins and keeps its place", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    const ran: string[] = [];
    lanes.frame("a", () => {
      ran.push("a1");
    });
    lanes.frame("b", () => {
      ran.push("b");
    });
    lanes.frame("a", () => {
      ran.push("a2");
    });
    expect(engine.pendingFrames()).toBe(1);
    expect(ran).toEqual([]);
    await engine.frame();
    expect(ran).toEqual(["a2", "b"]);
    expect(engine.pendingFrames()).toBe(0);
    lanes.dispose();
  });

  test("requests no frame with nothing queued (stop condition)", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    lanes.frame("a", () => {});
    await engine.frame();
    await engine.tasks();
    expect(engine.pendingFrames()).toBe(0);
    expect(engine.pendingTasks()).toBe(0);
    expect(engine.liveTimers()).toBe(0);
    lanes.dispose();
  });

  test("a slice stops at SLICE_MS and gives the thread back; the frame stops at FRAME_BUDGET_MS", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    const ran: number[] = [];
    for (let i = 0; i < 10; i++) {
      lanes.frame(`k${i}`, () => {
        ran.push(i);
        engine.advance(1.5);
      });
    }
    await engine.frame();
    // 1.5 ms each: the third task ends the 4 ms slice at 4.5 ms.
    expect(ran).toEqual([0, 1, 2]);
    expect(engine.pendingTasks()).toBe(1);
    await engine.tasks(1);
    // The continuation slice runs until the 6 ms frame budget is spent (one more 1.5 ms task).
    expect(ran).toEqual([0, 1, 2, 3]);
    expect(engine.now).toBeGreaterThanOrEqual(FRAME_BUDGET_MS);
    expect(engine.pendingFrames()).toBe(1);
    await engine.frame();
    expect(ran.length).toBeGreaterThan(5);
    lanes.dispose();
  });

  test("after a key, the frame runs one slice and waits for the next frame", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    const ran: number[] = [];
    for (let i = 0; i < 10; i++) {
      lanes.frame(`k${i}`, () => {
        ran.push(i);
        engine.advance(1.5);
      });
    }
    engine.fire("keydown");
    expect(lanes.inputPending()).toBe(true);
    await engine.frame();
    expect(ran).toEqual([0, 1, 2]);
    expect(engine.pendingTasks()).toBe(0);
    expect(engine.pendingFrames()).toBe(1);
    lanes.dispose();
  });

  test("a slice yields as soon as the engine reports pending input", async () => {
    let pending = false;
    const engine = fakeEngine({ engineInputPending: () => pending });
    const lanes = createLanes(engine.env);
    const ran: number[] = [];
    for (let i = 0; i < 4; i++) {
      lanes.frame(`k${i}`, () => {
        ran.push(i);
        engine.advance(0.5);
        pending = true;
      });
    }
    await engine.frame();
    expect(ran).toEqual([0]);
    lanes.dispose();
  });

  test("an async task that yields resumes in the frame lane's next slice", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    const steps: string[] = [];
    lanes.frame("parse", async (slice) => {
      for (let i = 0; i < 6; i++) {
        steps.push(`p${i}`);
        engine.advance(2);
        if (slice.shouldYield()) await lanes.yield();
      }
    });
    lanes.frame("after", () => {
      steps.push("after");
    });
    await engine.frame();
    expect(steps).toEqual(["p0", "p1"]);
    await engine.tasks(1);
    // The frame's 6 ms are spent after one more step.
    expect(steps).toEqual(["p0", "p1", "p2"]);
    await engine.frame();
    expect(steps).toEqual(["p0", "p1", "p2", "p3", "p4"]);
    await engine.tasks(1);
    expect(steps).toEqual(["p0", "p1", "p2", "p3", "p4", "p5"]);
    // The frame budget is spent; the next task waits for the next frame.
    await engine.frame();
    expect(steps).toEqual(["p0", "p1", "p2", "p3", "p4", "p5", "after"]);
    lanes.dispose();
  });

  test("a hidden page runs no frame work, and runs it on show", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    engine.setHidden(true);
    const ran: string[] = [];
    lanes.frame("a", () => {
      ran.push("a");
    });
    expect(engine.pendingFrames()).toBe(0);
    engine.setHidden(false);
    await engine.frame();
    expect(ran).toEqual(["a"]);
    lanes.dispose();
  });

  test("a task that throws is reported and the lane goes on", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    const ran: string[] = [];
    lanes.frame("bad", () => {
      throw new Error("boom");
    });
    lanes.frame("good", () => {
      ran.push("good");
    });
    await engine.frame();
    expect(ran).toEqual(["good"]);
    expect(engine.errors.length).toBe(1);
    lanes.dispose();
  });
});

describe("input tracking", () => {
  test("input counts as pending for INPUT_QUIET_MS after each of the four events", () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    expect(lanes.inputPending()).toBe(false);
    for (const type of ["keydown", "beforeinput", "pointerdown", "compositionstart"]) {
      engine.fire(type);
      expect(lanes.inputPending()).toBe(true);
      engine.advance(INPUT_QUIET_MS - 1);
      expect(lanes.inputPending()).toBe(true);
      engine.advance(1);
      expect(lanes.inputPending()).toBe(false);
    }
    lanes.dispose();
  });

  test("dispose removes every listener", () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    lanes.dispose();
    for (const set of engine.listeners.values()) expect(set.size).toBe(0);
  });
});

describe("idle lane", () => {
  test("runs after the frame lane is done, coalescing by key", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    const ran: string[] = [];
    lanes.frame("f", () => {
      ran.push("frame");
    });
    lanes.idle("draft", () => {
      ran.push("draft1");
    });
    lanes.idle("draft", () => {
      ran.push("draft2");
    });
    expect(engine.pendingTasks()).toBe(0);
    await engine.frame();
    await engine.tasks();
    expect(ran).toEqual(["frame", "draft2"]);
    lanes.dispose();
  });

  test("waits until input has been quiet INPUT_QUIET_MS, with one timer", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    const ran: string[] = [];
    engine.fire("keydown");
    lanes.idle("draft", () => {
      ran.push("draft");
    });
    expect(engine.pendingTasks()).toBe(0);
    expect(engine.liveTimers()).toBe(1);
    engine.advance(10);
    engine.fire("keydown");
    await engine.timer();
    // The second key moved the quiet point: still waiting, on one new timer.
    expect(ran).toEqual([]);
    expect(engine.liveTimers()).toBe(1);
    await engine.timer();
    await engine.tasks();
    expect(ran).toEqual(["draft"]);
    expect(engine.liveTimers()).toBe(0);
    lanes.dispose();
  });

  test("runs in slices of at most SLICE_MS", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    const ran: number[] = [];
    for (let i = 0; i < 5; i++) {
      lanes.idle(`k${i}`, () => {
        ran.push(i);
        engine.advance(SLICE_MS / 2 + 0.5);
      });
    }
    await engine.tasks(1);
    expect(ran).toEqual([0, 1]);
    await engine.tasks();
    expect(ran).toEqual([0, 1, 2, 3, 4]);
    lanes.dispose();
  });

  test("flush runs pending idle work now, all or one key", () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    const ran: string[] = [];
    engine.fire("keydown");
    lanes.idle("a", () => {
      ran.push("a");
    });
    lanes.idle("b", () => {
      ran.push("b");
    });
    lanes.flush("b");
    expect(ran).toEqual(["b"]);
    lanes.flush();
    expect(ran).toEqual(["b", "a"]);
    lanes.dispose();
  });

  test("on hide only durable keys run; the rest wait for show", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    const ran: string[] = [];
    engine.fire("keydown");
    lanes.idle(
      "draft",
      () => {
        ran.push("draft");
      },
      { durable: true },
    );
    lanes.idle("presence", () => {
      ran.push("presence");
    });
    engine.setHidden(true);
    expect(ran).toEqual(["draft"]);
    await engine.timer();
    await engine.tasks();
    expect(ran).toEqual(["draft"]);
    engine.setHidden(false);
    await engine.timer();
    await engine.tasks();
    expect(ran).toEqual(["draft", "presence"]);
    lanes.dispose();
  });

  test("pagehide flushes durable keys", () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    const ran: string[] = [];
    engine.fire("keydown");
    lanes.idle(
      "draft",
      () => {
        ran.push("draft");
      },
      { durable: true },
    );
    engine.fire("pagehide");
    expect(ran).toEqual(["draft"]);
    lanes.dispose();
  });
});

describe("yield outside a lane", () => {
  test("resolves on the next task", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    let done = false;
    void lanes.yield().then(() => {
      done = true;
    });
    await Promise.resolve();
    expect(done).toBe(false);
    await engine.tasks(1);
    expect(done).toBe(true);
    lanes.dispose();
  });
});

describe("a page that draws no frames", () => {
  test("runs its frame work after NO_FRAME_MS, once, and the late frame does nothing", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    const ran: string[] = [];
    lanes.frame("a", () => {
      ran.push("a");
    });
    expect(engine.liveTimers()).toBe(1);
    engine.advance(NO_FRAME_MS);
    await engine.timer();
    expect(ran).toEqual(["a"]);
    await engine.frame();
    expect(ran).toEqual(["a"]);
    expect(engine.liveTimers()).toBe(0);
    lanes.dispose();
  });

  test("a frame that comes cancels the fallback", async () => {
    const engine = fakeEngine();
    const lanes = createLanes(engine.env);
    lanes.frame("a", () => {});
    await engine.frame();
    expect(engine.liveTimers()).toBe(0);
    lanes.dispose();
  });
});
