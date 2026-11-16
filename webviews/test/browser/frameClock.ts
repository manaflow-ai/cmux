// A page clock that moves only with drawn frames, for motion checks that must not read a loaded
// host as motion (send-stream-motion.test.ts, `?clock=frames`). With it, support/frames120.ts gives
// every frame a time exactly one 120 Hz slot after the last (BeginFrame's `frameTimeTicks`), so frame
// callbacks, `document.timeline` and animations see a display that never drops a frame; this module
// puts the page's own `performance.now` and timers on that clock. What a frame draws (the deltas that
// landed, the reveal's step, the follow motion's step) then follows from how many frames came before
// it, not from how long the host took to draw them: a CPU stall delays the frames, it does not move
// more text or more pixels into one of them.
//
// - Frame `n` after install is at `install + n` slots exactly: `performance.now()`, the time frame
//   callbacks are given and `document.timeline.currentTime` read it (Chromium's own frame times are
//   rounded to 0.1 ms, which moved a timer due on a frame's edge, as a scripted 400 ms is, a frame
//   either way), and `performance.now()` reads a timer's due time while that timer runs.
// - `setTimeout` timers due before the next frame run after this frame, one task each in due order
//   (a posted message each), as a real timer that comes due between two frames runs before the
//   second; what they draw shows in the next frame.
// - `__frameIdle()` resolves once this frame's due timers ran and the work they posted (React's
//   commit, scheduled on a posted message) ran too: frames120 waits for it before it begins a frame.
//
// Stop condition: the frame loop is the page's (one callback a frame while the page lives); the timer
// chain runs only while a timer is due before the next frame.

const FRAME_MS = 1000 / 120;

type Timer = { id: number; due: number; run: () => void };

export function installFrameClock(): void {
  const realNow = performance.now.bind(performance);
  const realRaf = window.requestAnimationFrame.bind(window);
  const installed = realNow();
  let now = installed;
  /// Frames drawn since install, and the latest one's time.
  let frames = 0;
  let frameNow = installed;
  /// Timers due before this (the next frame's time) run before the next frame.
  let horizon = Number.NEGATIVE_INFINITY;
  const timers = new Map<number, Timer>();
  let nextId = 1;
  let firing = false;
  const fire = new MessageChannel();
  const hop = new MessageChannel();
  const idle: (() => void)[] = [];

  const due = () => {
    let first: Timer | undefined;
    for (const timer of timers.values())
      if (timer.due < horizon && (!first || timer.due < first.due || (timer.due === first.due && timer.id < first.id)))
        first = timer;
    return first;
  };
  fire.port1.onmessage = () => {
    const timer = due();
    if (!timer) {
      firing = false;
      return;
    }
    timers.delete(timer.id);
    now = Math.max(now, timer.due);
    fire.port2.postMessage(0);
    timer.run();
  };
  const startFiring = () => {
    if (firing || !due()) return;
    firing = true;
    fire.port2.postMessage(0);
  };
  // Three posted-message hops after the timers: the commit their updates scheduled, and the effects
  // that commit scheduled, run before the next frame begins.
  let hops = 0;
  hop.port1.onmessage = () => {
    if (firing) {
      hop.port2.postMessage(0);
      return;
    }
    hops -= 1;
    if (hops > 0) {
      hop.port2.postMessage(0);
      return;
    }
    for (const resolve of idle.splice(0)) resolve();
  };

  performance.now = () => now;
  const setTimeoutOnClock = (handler: TimerHandler, ms?: number, ...args: unknown[]) => {
    const id = nextId++;
    const run = typeof handler === "function" ? () => handler(...args) : () => {};
    timers.set(id, { id, due: now + Math.max(0, Number(ms) || 0), run });
    startFiring();
    return id;
  };
  window.setTimeout = setTimeoutOnClock as typeof window.setTimeout;
  window.clearTimeout = ((id?: number) => {
    if (id !== undefined) timers.delete(id);
  }) as typeof window.clearTimeout;

  // The first frame callback of every frame (it asks for the next one before any other callback
  // of this one can), so the frame's time is set before anything reads it.
  const frame = () => {
    realRaf(frame);
    frames += 1;
    frameNow = installed + frames * FRAME_MS;
    now = Math.max(now, frameNow);
    horizon = frameNow + FRAME_MS - 0.01;
    startFiring();
  };
  realRaf(frame);
  window.requestAnimationFrame = (callback) => realRaf(() => callback(frameNow));
  Object.defineProperty(document.timeline, "currentTime", { get: () => frameNow, configurable: true });

  (window as unknown as { __frameIdle: () => Promise<void> }).__frameIdle = () =>
    new Promise<void>((resolve) => {
      idle.push(resolve);
      if (hops === 0) {
        hops = 3;
        hop.port2.postMessage(0);
      }
    });
}

if (new URLSearchParams(location.search).get("clock") === "frames") installFrameClock();
