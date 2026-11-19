/**
 * Input first for the transcript's draws: an expensive stream draw gives the main thread back to keys.
 *
 * The chat draws one snapshot per display frame (`AcpmuxDirectClient.scheduleFrame`). A draw of a long chat
 * is a React render and commit plus the frame's style and layout, which cannot be cut in slices; at 6,000
 * rows it measured 15 to 70 ms (composer-typing.bench.ts --tasks). At 60 draws a second that is more than the
 * whole thread, so a key waits behind it. This pacer is the app lanes' rule (urgent, transition, idle; a turn
 * has a budget) applied to that draw:
 *
 * - urgent: a draw that is not paced (the person's own change, a chat switch) runs in the next frame, as
 *   before, and a paced draw waiting at the time is drawn with it.
 * - transition: a paced draw (agent events streaming in) runs in the next frame while draws are cheap.
 *   Once the last draw cost more than DRAW_FREE_MS, the next one waits until the thread had as much free
 *   time as that draw took (DRAW_SHARE: the stream gets at most half the thread), and while a key or a
 *   pointer press is pending it waits one more frame, so the key's frame paints first.
 * - anti-starvation: a paced draw never waits more than DRAW_MAX_WAIT_MS after it was asked for.
 *
 * A draw's cost is read from its start to the first task after it: its microtasks (React's sync render of a
 * store change), the React work it scheduled before that task and the frame's own style, layout and paint.
 * Every wait is a frame request of the scheduler it wraps, bounded by DRAW_MAX_WAIT_MS, and cancelled with
 * the draw.
 */

export type FrameSchedule = (run: () => void) => (() => void) | void;

export interface DrawPacerEnv {
  now(): number;
  /** The frame scheduler it paces (`nextFrame`); its hidden-page and no-frame rules stay its own. */
  frame: FrameSchedule;
  /** A key or pointer press is pending or was handled within the last frames (lanes.inputPending). */
  inputPending(): boolean;
  /** Runs `cb` in the first task after the current one. */
  afterTask(cb: () => void): void;
}

/** A draw at most this long is never paced: half a refresh at 60 Hz. */
export const DRAW_FREE_MS = 8;
/** The share of the main thread paced draws may take. */
export const DRAW_SHARE = 0.5;
/** A paced draw runs at most this long after it was asked for, whatever else is waiting. */
export const DRAW_MAX_WAIT_MS = 100;
/** Frames a paced draw waits for a pending key, in a row. */
export const INPUT_DEFER_FRAMES = 1;

export interface DrawPacer {
  /** Schedules `run` for a frame; `paced` marks it as stream work that may wait (see above). */
  schedule(run: () => void, paced?: boolean): () => void;
  /** The last draw's cost, ms, and how many paced draws waited (for the debug surface and tests). */
  stats(): DrawPacerStats;
  /** Zeroes the wait counts (the debug surface's resetTyping). */
  resetStats(): void;
}

export type DrawPacerStats = {
  draws: number;
  last_draw_ms: number;
  max_draw_ms: number;
  paced_waits: number;
  input_waits: number;
  starved_runs: number;
};

export function createDrawPacer(env: DrawPacerEnv): DrawPacer {
  let lastCost = 0;
  let lastEnd = Number.NEGATIVE_INFINITY;
  let measuring = false;
  let pacedWaits = 0;
  let inputWaits = 0;
  let starvedRuns = 0;
  let draws = 0;
  let maxCost = 0;

  function measured(run: () => void): void {
    const start = env.now();
    try {
      run();
    } finally {
      // One measurement at a time: two draws in one frame are read as one.
      if (!measuring) {
        measuring = true;
        env.afterTask(() => {
          measuring = false;
          lastEnd = env.now();
          lastCost = lastEnd - start;
          draws += 1;
          maxCost = Math.max(maxCost, lastCost);
        });
      }
    }
  }

  /** When the thread has had as much free time after the last expensive draw as that draw took. */
  function freeAt(): number {
    if (lastCost <= DRAW_FREE_MS) return Number.NEGATIVE_INFINITY;
    return lastEnd + (lastCost * (1 - DRAW_SHARE)) / DRAW_SHARE;
  }

  return {
    schedule(run, paced = false) {
      let cancelFrame: (() => void) | void = undefined;
      let done = false;
      if (!paced) {
        cancelFrame = env.frame(() => {
          if (done) return;
          done = true;
          measured(run);
        });
        return () => {
          done = true;
          cancelFrame?.();
        };
      }
      const asked = env.now();
      let inputDeferred = 0;
      const attempt = () => {
        if (done) return;
        const now = env.now();
        if (now - asked < DRAW_MAX_WAIT_MS) {
          if (now < freeAt()) {
            pacedWaits += 1;
            cancelFrame = env.frame(attempt);
            return;
          }
          if (lastCost > DRAW_FREE_MS && inputDeferred < INPUT_DEFER_FRAMES && env.inputPending()) {
            inputDeferred += 1;
            inputWaits += 1;
            cancelFrame = env.frame(attempt);
            return;
          }
        } else if (lastCost > DRAW_FREE_MS) starvedRuns += 1;
        done = true;
        measured(run);
      };
      cancelFrame = env.frame(attempt);
      return () => {
        done = true;
        cancelFrame?.();
      };
    },
    stats: () => ({
      draws,
      last_draw_ms: Math.round(lastCost * 100) / 100,
      max_draw_ms: Math.round(maxCost * 100) / 100,
      paced_waits: pacedWaits,
      input_waits: inputWaits,
      starved_runs: starvedRuns,
    }),
    resetStats() {
      draws = 0;
      maxCost = 0;
      pacedWaits = 0;
      inputWaits = 0;
      starvedRuns = 0;
    },
  };
}

/** The page's pacer, once the pane made it (mountModel.tsx), for the debug surface. */
let pagePacer: DrawPacer | undefined;

export function setPageDrawPacer(pacer: DrawPacer | undefined): void {
  pagePacer = pacer;
}

export function pageDrawPacer(): DrawPacer | undefined {
  return pagePacer;
}

/** One channel for the page: the first task after the current one, in order (as lanes.ts `messageTask`). */
let channel: MessageChannel | null = null;
const queued: (() => void)[] = [];

export function afterTask(cb: () => void): void {
  if (typeof MessageChannel === "undefined") {
    setTimeout(cb, 0);
    return;
  }
  if (channel == null) {
    channel = new MessageChannel();
    channel.port1.onmessage = () => queued.shift()?.();
  }
  queued.push(cb);
  channel.port2.postMessage(undefined);
}
