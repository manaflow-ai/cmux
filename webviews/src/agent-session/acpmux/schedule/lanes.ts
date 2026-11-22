/**
 * The agent pane's one scheduler: who gets the main thread, and when
 * (cmuxterm-hq docs/design/chat-instant-under-load.md, "Three lanes, strict priority").
 *
 * - input: keys, pointer, IME. Never scheduled here; it runs at once. This module only watches it,
 *   by capture-phase listeners, so the other lanes can step aside.
 * - frame: `lanes.frame(key, fn)` runs once in the next display frame. One rAF drives the lane; the
 *   lane spends at most FRAME_BUDGET_MS of a frame, in slices of at most SLICE_MS that give the
 *   thread back between them, and stops for the frame after a slice while input is pending. A hidden
 *   page runs no frame work.
 * - idle: `lanes.idle(key, fn)` runs when no input is pending and the frame lane has nothing left,
 *   in slices of at most SLICE_MS. A hidden page runs only the keys marked durable, and flushes them
 *   on hide.
 *
 * Same key, same lane: the latest fn replaces a queued one and keeps its place. A task may be async
 * and `await lanes.yield()` to give the thread back; it resumes in the same lane's next slice.
 *
 * Every wake-up here has a stop condition: the rAF is requested only while frame work is queued and
 * the page is visible, the idle task and its input-quiet timer only while idle work is queued, and
 * `dispose()` removes the listeners.
 */

export type LaneName = "frame" | "idle";

/** What a running task can ask of its slice. */
export interface Slice {
  /** Milliseconds left in this slice (never below 0). */
  timeLeft(): number;
  /** True when the task should `await lanes.yield()` now: its slice is spent or input is waiting. */
  shouldYield(): boolean;
}

export type LaneTask = (slice: Slice) => void | Promise<void>;

export interface IdleOptions {
  /** Runs on hide and while the page is hidden (draft writes): work that must not be lost. */
  durable?: boolean;
}

export interface Lanes {
  frame(key: string, fn: LaneTask): void;
  idle(key: string, fn: LaneTask, options?: IdleOptions): void;
  inputPending(): boolean;
  yield(): Promise<void>;
  flush(key?: string): void;
  /** Removes the listeners and drops queued work. For tests and teardown. */
  dispose(): void;
}

/** The engine the lanes run on; tests pass a fake one with a manual clock. */
export interface LanesEnv {
  now(): number;
  requestFrame(cb: () => void): void;
  /** One macrotask that does not wait for a frame and is not clamped. */
  postTask(cb: () => void, priority: "user-visible" | "background"): void;
  /** A one-shot timer (the input-quiet wait); returns a cancel. */
  setTimer(cb: () => void, ms: number): () => void;
  /** The engine's own pending-input signal (Chromium), when it has one. */
  engineInputPending?: () => boolean;
  /** Whether the page is hidden now. */
  hidden(): boolean;
  /** Listens on the window in the capture phase; returns a remove. */
  listen(type: string, cb: () => void): () => void;
  reportError(error: unknown): void;
}

export const FRAME_BUDGET_MS = 6;
export const SLICE_MS = 4;
/** A key or pointer handled this recently still counts as pending input. */
export const INPUT_QUIET_MS = 50;
/** A frame asked for that does not come in this long (an occluded window) runs anyway. */
export const NO_FRAME_MS = 50;

const INPUT_EVENTS = ["keydown", "beforeinput", "pointerdown", "compositionstart"] as const;

interface Entry {
  fn: LaneTask;
  durable: boolean;
}

interface LaneState {
  name: LaneName;
  queue: Map<string, Entry>;
  /** An async task that yielded: it resumes first in the lane's next slice. */
  resume: (() => void) | null;
  /** Ends the slice's wait on the running async task. */
  endTurn: (() => void) | null;
  /** A slice is executing (sync part or awaiting the running task). */
  inSlice: boolean;
  sliceStart: number;
}

export function createLanes(env: LanesEnv): Lanes {
  const frameLane: LaneState = lane("frame");
  const idleLane: LaneState = lane("idle");
  let lastInputAt = Number.NEGATIVE_INFINITY;
  let frameRequested = false;
  let frameStart = 0;
  let frameTaskPosted = false;
  let idleTaskPosted = false;
  let idleTimerCancel: (() => void) | null = null;
  /** The lane whose slice is running now; `yield()` resumes there. */
  let active: LaneState | null = null;
  let disposed = false;

  const removers = INPUT_EVENTS.map((type) =>
    env.listen(type, () => {
      lastInputAt = env.now();
    }),
  );
  removers.push(
    env.listen("visibilitychange", onVisibility),
    env.listen("pagehide", () => flushIdle(undefined, true)),
  );

  function lane(name: LaneName): LaneState {
    return { name, queue: new Map(), resume: null, endTurn: null, inSlice: false, sliceStart: 0 };
  }

  /** An input event is queued and not yet dispatched (Chromium only). */
  function inputWaiting(): boolean {
    try {
      return env.engineInputPending?.() === true;
    } catch {
      return false;
    }
  }

  function inputPending(): boolean {
    return env.now() - lastInputAt < INPUT_QUIET_MS || inputWaiting();
  }

  function hasWork(state: LaneState): boolean {
    return state.queue.size > 0 || state.resume !== null;
  }

  function hasDurableWork(state: LaneState): boolean {
    if (state.resume !== null) return true;
    for (const entry of state.queue.values()) if (entry.durable) return true;
    return false;
  }

  // ---- frame lane ----

  function scheduleFrame(): void {
    if (disposed || frameRequested || env.hidden() || !hasWork(frameLane)) return;
    frameRequested = true;
    let fired = false;
    // A shown page that draws no frames (an occluded window) still runs its frame work, after
    // NO_FRAME_MS, as the pane's `nextFrame` always did; whichever comes first runs, once.
    const cancelFallback = env.setTimer(() => run(), NO_FRAME_MS);
    const run = () => {
      if (fired) return;
      fired = true;
      cancelFallback();
      frameRequested = false;
      if (disposed) return;
      if (env.hidden()) return; // onVisibility schedules it again on show
      frameStart = env.now();
      // The first slice of a frame always runs: the frame's input was dispatched before the rAF.
      void runSlice(frameLane);
    };
    env.requestFrame(run);
  }

  function frameBudgetLeft(): number {
    return FRAME_BUDGET_MS - (env.now() - frameStart);
  }

  function afterFrameSlice(): void {
    if (disposed) return;
    if (hasWork(frameLane) && !env.hidden() && frameBudgetLeft() > 0 && !inputPending()) {
      // Give the thread back between slices, and go on in the same frame.
      if (!frameTaskPosted) {
        frameTaskPosted = true;
        env.postTask(() => {
          frameTaskPosted = false;
          if (disposed) return;
          if (frameBudgetLeft() > 0 && !inputPending()) void runSlice(frameLane);
          else scheduleFrame();
        }, "user-visible");
      }
      return;
    }
    scheduleFrame();
    scheduleIdle();
  }

  // ---- idle lane ----

  function idleMayRun(): boolean {
    if (hasWork(frameLane) && !env.hidden()) return false;
    return !inputPending();
  }

  function idleRunnable(): boolean {
    return env.hidden() ? hasDurableWork(idleLane) : hasWork(idleLane);
  }

  function scheduleIdle(): void {
    if (disposed || idleTaskPosted || idleTimerCancel || !idleRunnable()) return;
    if (hasWork(frameLane) && !env.hidden()) return; // the frame lane calls back when it is done
    const quietIn = lastInputAt + INPUT_QUIET_MS - env.now();
    if (quietIn > 0) {
      idleTimerCancel = env.setTimer(() => {
        idleTimerCancel = null;
        scheduleIdle();
      }, quietIn);
      return;
    }
    idleTaskPosted = true;
    env.postTask(() => {
      idleTaskPosted = false;
      if (disposed) return;
      if (!idleMayRun()) {
        scheduleIdle();
        return;
      }
      void runSlice(idleLane);
    }, "background");
  }

  // ---- slices ----

  function makeSlice(state: LaneState): Slice {
    const timeLeft = () => {
      let left = SLICE_MS - (env.now() - state.sliceStart);
      if (state === frameLane) left = Math.min(left, frameBudgetLeft());
      return Math.max(0, left);
    };
    return {
      timeLeft,
      // Mid-slice, only input that is waiting now ends the slice early (the engine says so, where it
      // can); the quiet window after a key ends the frame's work between slices instead.
      shouldYield: () => timeLeft() <= 0 || inputWaiting(),
    };
  }

  /** Takes the next queued entry, honouring hidden-page rules for idle work. */
  function takeNext(state: LaneState): Entry | null {
    for (const [key, entry] of state.queue) {
      if (state === idleLane && env.hidden() && !entry.durable) continue;
      state.queue.delete(key);
      return entry;
    }
    return null;
  }

  /** Ends the slice's wait on the running async task: it finished, or it yielded into `resume`. */
  function endTurn(state: LaneState): void {
    const settle = state.endTurn;
    state.endTurn = null;
    settle?.();
  }

  /** Runs `start` with the lane active and waits until its task finishes or yields. */
  function turn(state: LaneState, start: () => void): Promise<void> {
    return new Promise<void>((resolve) => {
      state.endTurn = resolve;
      active = state;
      start();
    });
  }

  function watchTask(state: LaneState, task: Promise<void>): void {
    task.then(
      () => endTurn(state),
      (error) => {
        env.reportError(error);
        endTurn(state);
      },
    );
  }

  async function runSlice(state: LaneState): Promise<void> {
    if (state.inSlice) return;
    state.inSlice = true;
    state.sliceStart = env.now();
    const slice = makeSlice(state);
    let ran = false;
    try {
      while (!disposed) {
        if (ran && slice.shouldYield()) break;
        if (state === idleLane && !idleMayRun()) break;
        if (state.resume) {
          ran = true;
          const resume = state.resume;
          state.resume = null;
          await turn(state, resume);
          active = null;
          if (state.resume) break; // it yielded again: its slice is over
          continue;
        }
        const entry = takeNext(state);
        if (!entry) break;
        ran = true;
        let result: void | Promise<void> = undefined;
        active = state;
        try {
          result = entry.fn(slice);
        } catch (error) {
          env.reportError(error);
        }
        active = null;
        if (!result || typeof (result as Promise<void>).then !== "function") continue;
        const task = result as Promise<void>;
        if (state.resume) {
          // It yielded before its first await: its turn is already over.
          watchTask(state, task);
          break;
        }
        await turn(state, () => watchTask(state, task));
        active = null;
        if (state.resume) break;
      }
    } finally {
      active = null;
      state.inSlice = false;
    }
    if (state === frameLane) afterFrameSlice();
    else scheduleIdle();
  }

  function laneYield(): Promise<void> {
    const state = active;
    if (!state || !state.inSlice) return plainYield();
    return new Promise<void>((resolve) => {
      state.resume = resolve;
      active = null;
      endTurn(state);
    });
  }

  function plainYield(): Promise<void> {
    return new Promise((resolve) => env.postTask(resolve, "user-visible"));
  }

  // ---- flush and visibility ----

  function flushIdle(key: string | undefined, durableOnly: boolean): void {
    if (disposed) return;
    const entries: Entry[] = [];
    if (key !== undefined) {
      const entry = idleLane.queue.get(key);
      if (entry && (!durableOnly || entry.durable)) {
        idleLane.queue.delete(key);
        entries.push(entry);
      }
    } else {
      for (const [k, entry] of idleLane.queue) {
        if (durableOnly && !entry.durable) continue;
        idleLane.queue.delete(k);
        entries.push(entry);
      }
    }
    const slice: Slice = { timeLeft: () => Number.POSITIVE_INFINITY, shouldYield: () => false };
    for (const entry of entries) {
      try {
        const result = entry.fn(slice);
        if (result && typeof (result as Promise<void>).then === "function") {
          (result as Promise<void>).catch(env.reportError);
        }
      } catch (error) {
        env.reportError(error);
      }
    }
  }

  function onVisibility(): void {
    if (env.hidden()) {
      flushIdle(undefined, true);
      return;
    }
    scheduleFrame();
    scheduleIdle();
  }

  return {
    frame(key, fn) {
      if (disposed) return;
      const existing = frameLane.queue.get(key);
      if (existing) existing.fn = fn;
      else frameLane.queue.set(key, { fn, durable: false });
      scheduleFrame();
    },
    idle(key, fn, options) {
      if (disposed) return;
      const durable = options?.durable === true;
      const existing = idleLane.queue.get(key);
      if (existing) {
        existing.fn = fn;
        existing.durable = existing.durable || durable;
      } else idleLane.queue.set(key, { fn, durable });
      scheduleIdle();
    },
    inputPending,
    yield: laneYield,
    flush(key) {
      flushIdle(key, false);
    },
    dispose() {
      disposed = true;
      for (const remove of removers) remove();
      idleTimerCancel?.();
      idleTimerCancel = null;
      frameLane.queue.clear();
      idleLane.queue.clear();
    },
  };
}

// ---- the browser engine ----

interface PostTaskScheduler {
  postTask(cb: () => void, options?: { priority?: string }): Promise<unknown>;
}

/** One channel for the page (as React's scheduler does): a channel per task would never be collected. */
let channel: MessageChannel | null = null;
const channelQueue: (() => void)[] = [];

function messageTask(cb: () => void): void {
  if (channel == null) {
    channel = new MessageChannel();
    channel.port1.onmessage = () => channelQueue.shift()?.();
  }
  channelQueue.push(cb);
  channel.port2.postMessage(undefined);
}

export function browserLanesEnv(win: Window = window): LanesEnv {
  const scheduler = (win as unknown as { scheduler?: PostTaskScheduler }).scheduler;
  const scheduling = (
    win.navigator as unknown as {
      scheduling?: { isInputPending?: (options?: { includeContinuous?: boolean }) => boolean };
    }
  ).scheduling;
  return {
    now: () => win.performance.now(),
    requestFrame: (cb) => {
      win.requestAnimationFrame(() => cb());
    },
    postTask: (cb, priority) => {
      if (scheduler && typeof scheduler.postTask === "function") {
        void scheduler.postTask(cb, { priority }).catch(() => undefined);
      } else {
        messageTask(cb);
      }
    },
    setTimer: (cb, ms) => {
      const id = win.setTimeout(cb, ms);
      return () => win.clearTimeout(id);
    },
    engineInputPending:
      scheduling && typeof scheduling.isInputPending === "function"
        ? () => scheduling.isInputPending!({ includeContinuous: false })
        : undefined,
    hidden: () => win.document.visibilityState === "hidden",
    listen: (type, cb) => {
      const target: EventTarget = type === "visibilitychange" ? win.document : win;
      const options = { capture: true, passive: true } as const;
      target.addEventListener(type, cb, options);
      return () => target.removeEventListener(type, cb, options);
    },
    reportError: (error) => {
      if (typeof win.reportError === "function") win.reportError(error);
      else console.error(error);
    },
  };
}

let shared: Lanes | null = null;

/** The page's lanes, made on first use. */
export function pageLanes(): Lanes {
  shared ??= createLanes(browserLanesEnv());
  return shared;
}
