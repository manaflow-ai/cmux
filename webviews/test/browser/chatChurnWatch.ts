// The churn watcher (chat-sim.harness.tsx `live`): reads every drawn transcript row each frame while a
// chat plays with the pane's motion on, and counts what a reader following the chat sees move or blink.
//
// Leo, 2026-11-22: "the content within neeeds to be fucking settling fucking night instantly without
// extraneous movement", "i am still seeing flickers and flashes of bullshit. sub-second in and out
// bullshit." Rule (hq#18682): "an animation plays only for a change the reader caused or is looking at,
// and only where they can see it."
//
// - A shift: a row drawn in two frames in a row moved relative to the reader's anchor (the lowest row
//   drawn in both frames that is not a live line). Content added under the anchor, or text streaming
//   into it, moves nothing above it; a row above folding, unfolding, coming or going, or changing height
//   does. Consecutive frames that move are one shift (an animation is one event, CLS-style).
// - A flash: a row on screen for under a second (it came and went before it could be read).
// - A blink: a row that left the screen and came back within half a second.
import { TRANSCRIPT_ROW } from "../../src/agent-session/acpmux/transcriptSelectors";

export const FLASH_MS = 1_000;
export const BLINK_MS = 500;

export type ChurnShift = {
  /** ms since the watch started, at the shift's first frame. */
  at: number;
  /** The step the chat was at (its label). */
  step: string;
  frames: number;
  /** The rows that moved (ids), and the largest move (px). */
  rows: string[];
  px: number;
  anchor: string;
};
export type ChurnFlash = { id: string; kind: string; at: number; step: string; shownMs: number };
export type ChurnBlink = { id: string; at: number; step: string; goneMs: number };
export type ChurnReport = {
  durationMs: number;
  frames: number;
  shifts: ChurnShift[];
  flashes: ChurnFlash[];
  blinks: ChurnBlink[];
};

// Live lines: the running turn's status line and the room under it, which move with the stream by design.
const LIVE = /(^|-)live$|^typing|^thinking|^working-|^nextStep-/;
const kindOf = (element: HTMLElement) =>
  [...element.classList].find((name) => name.startsWith("acpmux-row--"))?.slice("acpmux-row--".length) ?? "";

export function watchChurn(scroller: HTMLElement) {
  const started = performance.now();
  let step = "";
  let frames = 0;
  let stopped = false;
  let previous = new Map<string, number>();
  let open: ChurnShift | undefined;
  const shifts: ChurnShift[] = [];
  const flashes: ChurnFlash[] = [];
  const blinks: ChurnBlink[] = [];
  /** Since when each row id has been on screen, and its kind. */
  const shown = new Map<string, { since: number; kind: string; step: string }>();
  /** Rows that left the screen: when, and for how long they had been on it. */
  const left = new Map<string, { at: number; shownMs: number; kind: string; step: string }>();

  const tick = () => {
    if (stopped) return;
    const now = performance.now() - started;
    frames += 1;
    const view = scroller.getBoundingClientRect();
    const tops = new Map<string, number>();
    const order: string[] = [];
    for (const element of document.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)) {
      const rect = element.getBoundingClientRect();
      if (rect.height <= 0 || rect.bottom <= view.top || rect.top >= view.bottom) continue;
      if (Number(getComputedStyle(element).opacity) < 0.05) continue;
      const id = element.dataset.rowId!;
      tops.set(id, rect.top);
      order.push(id);
      if (!shown.has(id)) {
        const gone = left.get(id);
        if (gone && now - gone.at < BLINK_MS) blinks.push({ id, at: now, step, goneMs: Math.round(now - gone.at) });
        left.delete(id);
        shown.set(id, { since: now, kind: kindOf(element), step });
      }
    }
    for (const [id, was] of shown) {
      if (tops.has(id)) continue;
      shown.delete(id);
      left.set(id, { at: now, shownMs: now - was.since, kind: was.kind, step: was.step });
    }
    // A row that left and stayed gone past the blink window: a flash if it was on screen under a second.
    for (const [id, gone] of left) {
      if (now - gone.at < BLINK_MS) continue;
      left.delete(id);
      if (gone.shownMs < FLASH_MS)
        flashes.push({
          id,
          kind: gone.kind,
          at: Math.round(gone.at),
          step: gone.step,
          shownMs: Math.round(gone.shownMs),
        });
    }
    // The anchor: the lowest row on screen in both frames that is not a live line.
    let anchor: string | undefined;
    for (let at = order.length - 1; at >= 0 && !anchor; at -= 1)
      if (previous.has(order[at]!) && !LIVE.test(order[at]!)) anchor = order[at];
    const moved: string[] = [];
    let px = 0;
    if (anchor) {
      const base = tops.get(anchor)!;
      const was = previous.get(anchor)!;
      for (const id of order) {
        if (id === anchor) break;
        const before = previous.get(id);
        if (before === undefined || LIVE.test(id)) continue;
        const delta = Math.abs(tops.get(id)! - base - (before - was));
        if (delta > 0.5) {
          moved.push(id);
          px = Math.max(px, delta);
        }
      }
    }
    if (moved.length) {
      if (!open) {
        open = { at: Math.round(now), step, frames: 0, rows: [], px: 0, anchor: anchor! };
        shifts.push(open);
      }
      open.frames += 1;
      open.px = Math.max(open.px, Math.round(px));
      for (const id of moved) if (!open.rows.includes(id)) open.rows.push(id);
    } else open = undefined;
    previous = tops;
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);

  return {
    /** The step the chat is at now (each shift and flash names it). */
    mark(label: string) {
      step = label;
    },
    stop(): ChurnReport {
      stopped = true;
      const now = performance.now() - started;
      for (const [id, gone] of left)
        if (gone.shownMs < FLASH_MS)
          flashes.push({
            id,
            kind: gone.kind,
            at: Math.round(gone.at),
            step: gone.step,
            shownMs: Math.round(gone.shownMs),
          });
      return { durationMs: Math.round(now), frames, shifts, flashes, blinks };
    },
  };
}
