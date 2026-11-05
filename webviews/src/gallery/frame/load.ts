// The load axis (env.ts LOADS): the stage on a machine that is doing other work. In the app the web
// views share the Mac with builds, other chats' streams, a browser and the native chrome, so a
// page's main thread rarely has a whole frame to itself. Here the frame takes part of every
// animation frame from its own main thread and adds a periodic long task, so a menu, an animation
// or a streaming reply is tried under the contention people run it in. Gallery only: nothing in the
// app reads this.
import type { GalleryLoad } from "../env";

export type LoadProfile = {
  /** Main-thread time taken from every animation frame (of about 16.7 ms at 60 Hz). */
  frameMs: number;
  /** One long task this long... */
  longTaskMs: number;
  /** ...every this many ms. */
  longTaskEveryMs: number;
};

/**
 * `busy`: about a third of each frame gone and a long task every 1.5 s, a Mac compiling beside a
 * few chats. `saturated`: about two thirds of each frame and a quarter-second stall every 2 s, every
 * core taken (a Release compile, a test suite, a dozen streaming chats).
 */
export const LOAD_PROFILES: Record<Exclude<GalleryLoad, "none">, LoadProfile> = {
  busy: { frameMs: 6, longTaskMs: 80, longTaskEveryMs: 1500 },
  saturated: { frameMs: 11, longTaskMs: 250, longTaskEveryMs: 2000 },
};

/** What the load took so far; the matrix runner and tests read it from `window.cmuxGalleryLoad`. */
export type LoadStats = { load: GalleryLoad; frames: number; longTasks: number; blockedMs: number };

declare global {
  interface Window {
    cmuxGalleryLoad?: LoadStats;
  }
}

/** Spins the main thread for `ms` (performance.now: the gallery clock leaves it untouched). */
function spin(ms: number): number {
  const start = performance.now();
  while (performance.now() - start < ms) {
    // Busy: the point is to hold the thread.
  }
  return performance.now() - start;
}

/**
 * Starts `load` in this frame and returns its stop. It stops by itself when the frame goes away
 * (pagehide); a hidden frame gets no animation frames, so only the long-task timer runs there.
 */
export function startGalleryLoad(load: GalleryLoad | undefined, win: Window = window): () => void {
  if (!load || load === "none") return () => {};
  const profile = LOAD_PROFILES[load];
  const stats: LoadStats = { load, frames: 0, longTasks: 0, blockedMs: 0 };
  win.cmuxGalleryLoad = stats;
  let stopped = false;
  let raf = 0;
  const frame = () => {
    if (stopped) return;
    stats.frames += 1;
    stats.blockedMs += spin(profile.frameMs);
    raf = win.requestAnimationFrame(frame);
  };
  raf = win.requestAnimationFrame(frame);
  const timer = win.setInterval(() => {
    stats.longTasks += 1;
    stats.blockedMs += spin(profile.longTaskMs);
  }, profile.longTaskEveryMs);
  const stop = () => {
    if (stopped) return;
    stopped = true;
    win.cancelAnimationFrame(raf);
    win.clearInterval(timer);
    win.removeEventListener("pagehide", stop);
  };
  win.addEventListener("pagehide", stop);
  return stop;
}
