// The running turn's live line holds still at the bottom while the reply above it chases home
// (Leo, 2026-11-11, on his NIGHTLY's reply landing: "this sequence is just absolute death ... the
// animation system is so borked and unintegrated").
//
// While the view follows a running turn, each line the reply grows by moves the scroll offset to the
// new end at once, and the follow chase (followChase.ts) draws the whole thread back by it and brings
// it home on its spring. The live line under the reply took that growth on a glide of its own
// (tailGlide.ts, the 80 ms arrival step, down) while the chase raised the thread over about 180 ms
// (up): two curves on one row, so it bobbed down and back on every line, 17 to 21 times a reply
// (agent-pane-turn-end-motion.test.ts).
//
// The followed view's last row already lies at the view's end in layout, so the one motion that keeps
// it still is none. While pinned, the chase's own frame (followChase `draw`) draws the live line
// against the thread's offset (`translate: 0 -x`) and clips the row over it at the line's drawn top
// by the same x, in the same frame, as plain px: one transform for the thread and the line, the
// reply's newest line showing from under the live line as the chase brings it up, and nothing drawn
// over the next row. The live line never glides then (tailGlide `pinned`).
//
// Pinned only while the live line is the thread's last row and the rows that come are not a send's
// (the send's rows rise out from behind the composer together, the live line with them), and never
// through the turn's end (its fold moves the rows itself). Unpinned while the thread is still drawn
// away, the line plays from where it was drawn home on the arrival step, so it never jumps.
//
// Inline `translate` and `clip-path` only: no layout, so the virtualizer's heights and the scroll
// offset stay exact. O(1) a frame: the live row and the row over it, kept from the pass. Reduce Motion
// and motion off never move the chase (x stays 0), so this draws nothing.
import { LIVE_THINKING } from "./turns";

export const PIN_LIVE_ATTR = "data-pin-live";

type Pinned = {
  live: HTMLElement;
  /// The rows over the live line that its held place can cover, with their layout bottoms.
  above: { row: HTMLElement; bottom: number }[];
  /// The live line's layout top in the thread.
  top: number;
  /// The thread offset last drawn against.
  x: number;
};
const pinned = new WeakMap<HTMLElement, Pinned>();

/// What the line was held back by when it was let go: the glide of the same pass (tailGlide.ts) starts
/// it from there. `used` once a glide took it.
export type PinCarry = { id: string; y: number; used: boolean };

/// How far `thread` is drawn from its layout now (its inline translate's y).
function threadY(thread: HTMLElement): number {
  const y = Number.parseFloat(thread.style.translate.split(" ")[1] ?? "");
  return Number.isFinite(y) ? y : 0;
}

function clear(rows: Pinned) {
  rows.live.style.removeProperty("translate");
  for (const { row } of rows.above) row.style.removeProperty("clip-path");
}

/// The rows over `live` (earlier siblings), nearest first, until one ends more than `reach` above it.
function rowsAbove(live: HTMLElement, reach: number): { row: HTMLElement; bottom: number }[] {
  const out: { row: HTMLElement; bottom: number }[] = [];
  for (let at = live.previousElementSibling; at; at = at.previousElementSibling) {
    if (!(at instanceof HTMLElement) || !at.classList.contains("acpmux-row")) continue;
    const bottom = at.offsetTop + at.offsetHeight;
    if (bottom < live.offsetTop - reach) break;
    if (at.offsetHeight > 0) out.push({ row: at, bottom });
  }
  return out;
}

/// Ends the clip animations playing on `row` (Web Animations override its inline clip). O(its own).
function dropClipGlides(row: HTMLElement) {
  if (typeof row.getAnimations !== "function") return;
  for (const animation of row.getAnimations()) {
    const effect = animation.effect as KeyframeEffect | null;
    if (effect?.getKeyframes?.().some((frame) => "clipPath" in frame)) animation.cancel();
  }
}

/// Draws the pinned live line of `thread` against the thread's offset `x`: the chase's frame calls
/// it with the thread's translate. Each row over it is clipped where it would pass the line's drawn
/// top. Nothing pinned: nothing drawn.
export function drawPinned(thread: HTMLElement, x: number): void {
  const rows = pinned.get(thread);
  if (!rows) return;
  rows.x = x;
  if (Math.abs(x) < 0.25) {
    clear(rows);
    return;
  }
  rows.live.style.translate = `0 ${-x}px`;
  for (const { row, bottom } of rows.above) {
    // A glide's clip on the row (tailGlide.ts) would win over this one: the pin's clip is the row's
    // whole clip while it holds, so that one ends.
    dropClipGlides(row);
    const over = bottom + x - rows.top;
    if (over > 0.25) row.style.clipPath = `inset(-4096px -4096px ${Math.ceil(over)}px -4096px)`;
    else row.style.removeProperty("clip-path");
  }
}

/// Pins the live line in `thread` (or unpins it, `pin` false) for this placement pass. Let go while
/// it was held away from the thread's offset, it returns what it was held back by for the pass's glide
/// to start from; `settle` plays it home if no glide takes it (`finish`).
export function pinLiveLine(thread: HTMLElement | null, pin: boolean): PinCarry | undefined {
  if (!thread) return undefined;
  const was = pinned.get(thread);
  const live = pin ? thread.querySelector<HTMLElement>(`:scope > .acpmux-row[data-row-id="${LIVE_THINKING}"]`) : null;
  if (live) {
    const x = threadY(thread);
    if (was) clear(was);
    // A row over the line lies under its held place by at most the most the chase holds back.
    const reach = Math.max(Math.abs(x), thread.ownerDocument.defaultView?.innerHeight ?? 0);
    pinned.set(thread, { live, above: rowsAbove(live, reach), top: live.offsetTop, x: was?.x ?? 0 });
    thread.setAttribute(PIN_LIVE_ATTR, "");
    drawPinned(thread, x);
    return undefined;
  }
  if (!was) return undefined;
  pinned.delete(thread);
  thread.removeAttribute(PIN_LIVE_ATTR);
  clear(was);
  if (!was.live.isConnected || Math.abs(was.x) < 0.5) return undefined;
  // Drawn at its place in the thread's layout, the thread itself drawn `x` away: it was `-x` from
  // where the thread draws it now.
  return { id: LIVE_THINKING, y: was.x, used: false };
}

/// Plays a line let go and not taken by a glide home from where it was held, on `step`.
export function finishCarry(
  thread: HTMLElement | null,
  carry: PinCarry | undefined,
  step: (px: number) => { ms: number; easing: string },
): void {
  if (!thread || !carry || carry.used) return;
  const row = thread.querySelector<HTMLElement>(`:scope > .acpmux-row[data-row-id="${carry.id}"]`);
  if (!row || typeof row.animate !== "function") return;
  const { ms, easing } = step(carry.y);
  if (ms > 0) row.animate([{ translate: `0 ${-carry.y}px` }, { translate: "0 0" }], { duration: ms, easing });
}
