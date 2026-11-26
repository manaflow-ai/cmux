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
  /** What changed between the moved rows and the anchor in the shift's first frame: `+id` came,
   *  `-id` went, `~id+Npx` changed height. */
  cause: string[];
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
const LIVE = /(^|-)live$|^typing|^thinking|^working-/;
// A turn's next-step card (its wrap-up recap or ask) sits under the turn's last reply, over the live
// line. While it is the tail (only live lines under it) a reply streaming in over it pushes it down by
// design, as it does the live line: it is no anchor then, and its moves are no shift. Anywhere else (a
// card in an earlier turn) it is a row like any other.
const TAIL_CARD = /^nextStep-/;
const kindOf = (element: HTMLElement) =>
  [...element.classList].find((name) => name.startsWith("acpmux-row--"))?.slice("acpmux-row--".length) ?? "";

export function watchChurn(scroller: HTMLElement) {
  const started = performance.now();
  let step = "";
  let frames = 0;
  let stopped = false;
  let previous = new Map<string, number>();
  let previousHeights = new Map<string, number>();
  let previousOrder: string[] = [];
  let previousText = new Map<string, string>();
  let previousClass = new Map<string, string>();
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
    const heights = new Map<string, number>();
    const texts = new Map<string, string>();
    const classOf = new Map<string, string>();
    const order: string[] = [];
    for (const element of document.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)) {
      const rect = element.getBoundingClientRect();
      if (rect.height <= 0 || rect.bottom <= view.top || rect.top >= view.bottom) continue;
      if (Number(getComputedStyle(element).opacity) < 0.05) continue;
      const id = element.dataset.rowId!;
      tops.set(id, rect.top);
      heights.set(id, rect.height);
      texts.set(id, element.textContent ?? "");
      classOf.set(id, `${element.className} [${[...element.querySelectorAll("[class]")].length} nodes]`);
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
    // The tail: the live lines at the end, and a next-step card among them.
    const tail = new Set<string>();
    for (let at = order.length - 1; at >= 0 && (LIVE.test(order[at]!) || TAIL_CARD.test(order[at]!)); at -= 1)
      tail.add(order[at]!);
    const live = (id: string) => LIVE.test(id) || tail.has(id);
    // The anchor: the lowest row on screen in both frames that is not a live line.
    let anchor: string | undefined;
    for (let at = order.length - 1; at >= 0 && !anchor; at -= 1)
      if (previous.has(order[at]!) && !live(order[at]!)) anchor = order[at];
    const moved: string[] = [];
    let px = 0;
    if (anchor) {
      const base = tops.get(anchor)!;
      const was = previous.get(anchor)!;
      for (const id of order) {
        if (id === anchor) break;
        const before = previous.get(id);
        if (before === undefined || live(id)) continue;
        const delta = Math.abs(tops.get(id)! - base - (before - was));
        if (delta > 0.5) {
          moved.push(id);
          px = Math.max(px, delta);
        }
      }
    }
    if (moved.length) {
      if (!open) {
        // The cause: rows between the highest moved row and the anchor that came, went or resized.
        const cause: string[] = [];
        const from = order.indexOf(moved[0]!);
        const to = order.indexOf(anchor!);
        for (const id of order.slice(from, to + 1)) {
          const was = previousHeights.get(id);
          if (was === undefined) cause.push(`+${id}`);
          else if (Math.abs(heights.get(id)! - was) > 0.5) {
            cause.push(`~${id}${heights.get(id)! > was ? "+" : ""}${Math.round(heights.get(id)! - was)}px`);
            const before = previousText.get(id) ?? "";
            const after = texts.get(id) ?? "";
            if (before !== after) {
              let head = 0;
              while (head < before.length && before[head] === after[head]) head += 1;
              let tail = 0;
              while (tail < before.length - head && before.at(-1 - tail) === after.at(-1 - tail)) tail += 1;
              cause.push(
                `  text @${head}: ${JSON.stringify(before.slice(head, before.length - tail).slice(0, 200))} -> ${JSON.stringify(after.slice(head, after.length - tail).slice(0, 200))}`,
              );
            }
            const classes = previousClass.get(id);
            if (classes !== classOf.get(id)) cause.push(`  class ${classes} -> ${classOf.get(id)}`);
          }
        }
        const wasFrom = previousOrder.indexOf(moved[0]!);
        const wasTo = previousOrder.indexOf(anchor!);
        if (wasFrom >= 0 && wasTo >= 0)
          for (const id of previousOrder.slice(wasFrom, wasTo)) if (!tops.has(id)) cause.push(`-${id}`);
        open = { at: Math.round(now), step, frames: 0, rows: [], px: 0, anchor: anchor!, cause };
        shifts.push(open);
      }
      open.frames += 1;
      open.px = Math.max(open.px, Math.round(px));
      for (const id of moved) if (!open.rows.includes(id)) open.rows.push(id);
    } else open = undefined;
    previous = tops;
    previousHeights = heights;
    previousOrder = order;
    previousText = texts;
    previousClass = classOf;
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
