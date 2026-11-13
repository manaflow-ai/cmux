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
  /// How far the line still rides with the thread: taken while the chase was drawn away, the line
  /// keeps its drawn place (it never jumps by the offset); it holds still as the thread is drawn
  /// further away and comes home with the thread as it comes back (`cap` only shrinks, to 0).
  cap: number;
  /// What the line was held back by as last painted, noted as the placement pass begins
  /// (`notePinPass`): the pass's own chase moves `x` before the pin is let go in it.
  painted?: number;
  /// The reader took the view: the line and its clips hold where they are drawn.
  held?: boolean;
};
const pinned = new WeakMap<HTMLElement, Pinned>();
const watchedGlides = new WeakSet<Animation>();

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
  if (!rows || rows.held) return;
  rows.cap = Math.max(0, Math.min(rows.cap, x));
  rows.x = x;
  // Held back by what the thread is drawn away past the line's cap.
  const held = x - rows.cap;
  // Read every gliding offset before changing any row's translate or clip.
  const above = rows.above.map(({ row, bottom }) => {
    const slides = translating(row);
    const translate = slides.length ? row.ownerDocument.defaultView?.getComputedStyle(row).translate : undefined;
    const offset = Number.parseFloat(translate?.split(" ")[1] ?? "") || 0;
    return { row, slides, over: bottom + held + offset - rows.top };
  });
  if (Math.abs(held) < 0.25) rows.live.style.removeProperty("translate");
  else rows.live.style.translate = `0 ${-held}px`;
  for (const { row, slides, over } of above) {
    for (const slide of slides) {
      if (watchedGlides.has(slide)) continue;
      watchedGlides.add(slide);
      const done = () => {
        slide.removeEventListener("finish", done);
        slide.removeEventListener("cancel", done);
        refreshPinned(thread);
      };
      slide.addEventListener("finish", done);
      slide.addEventListener("cancel", done);
    }
    if (over > 0.25) {
      // A glide's clip on the row (tailGlide.ts) would win over this one: where the line's held place
      // reaches the row, the pin's clip is its whole clip, so that one ends. Only there: a row the line
      // does not reach keeps the clip a glide set against a row gliding under it (rows that came over
      // the pinned line glide among themselves).
      dropClipGlides(row);
      row.style.clipPath = `inset(-4096px -4096px ${Math.ceil(over)}px -4096px)`;
    } else row.style.removeProperty("clip-path");
  }
}

/// A placement pass started or retargeted tail glides after taking the pin: update its clips before paint.
export function refreshPinned(thread: HTMLElement | null): void {
  if (thread) drawPinned(thread, threadY(thread));
}

/// The placement pass begins: what the pin holds the line back by now is what the reader sees. A
/// line let go in this pass carries that, never the rise this pass's chase notes before the pin
/// is let go (the pass's glide already starts the line from that: counted twice, the line jumped
/// 105 px when a steer prompt came over it in turn-transition-jumps steer-tools). O(1).
export function notePinPass(thread: HTMLElement | null): void {
  const rows = thread ? pinned.get(thread) : undefined;
  if (rows) rows.painted = rows.x - rows.cap;
}

/// Pins the live line in `thread` (or unpins it, `pin` false) for this placement pass. Let go while
/// it was held away from the thread's offset, it returns what it was held back by for the pass's glide
/// to start from; `settle` plays it home if no glide takes it (`finish`).
/// Whether `row` plays a translate of its own (a glide, a send's rise, a carry home). O(its own).
function moving(row: HTMLElement): boolean {
  return translating(row).length > 0;
}

function translating(row: HTMLElement): Animation[] {
  if (typeof row.getAnimations !== "function") return [];
  return row.getAnimations().filter((animation) => {
    if (animation.playState === "finished" || animation.playState === "idle") return false;
    const frames = (animation.effect as KeyframeEffect | null)?.getKeyframes?.();
    return frames?.some((frame) => "translate" in frame || "transform" in frame) ?? false;
  });
}

/// `hold`: the reader took the view. What the pin draws holds where it is (as the chase and the row
/// glides hold, tailGlide `hold`), never played home under the reader's own scroll; the pin draws on
/// once the view follows again.
export function pinLiveLine(thread: HTMLElement | null, pin: boolean, hold = false): PinCarry | undefined {
  if (!thread) return undefined;
  const was = pinned.get(thread);
  if (was && !pin && hold && was.live.isConnected) {
    was.held = true;
    return undefined;
  }
  const found = pin ? thread.querySelector<HTMLElement>(`:scope > .acpmux-row[data-row-id="${LIVE_THINKING}"]`) : null;
  // A line that plays a translate of its own (a send's rise, a carry home) finishes it first: taken
  // mid-way, the pin's translate would lose to it, or cancelling it would jump the line. The next pass
  // takes it.
  const live = found && (was?.live === found || !moving(found)) ? found : null;
  if (live) {
    const x = threadY(thread);
    if (was) clear(was);
    // A row over the line lies under its held place by at most the most the chase holds back.
    const reach = Math.max(Math.abs(x), thread.ownerDocument.defaultView?.innerHeight ?? 0);
    // Taken fresh, the line is drawn where the thread draws it (`cap` the thread's offset): the pin
    // starts from there, never jumping it by the offset the chase is still bringing home (105 px in
    // turn-transition-jumps steer-tools, the line taken again mid-chase after a steer's rise).
    const kept = was?.live === live;
    const cap = kept ? was.cap : Math.max(0, x);
    pinned.set(thread, { live, above: rowsAbove(live, reach), top: live.offsetTop, x: kept ? was.x : x, cap });
    thread.setAttribute(PIN_LIVE_ATTR, "");
    drawPinned(thread, x);
    return undefined;
  }
  if (!was) return undefined;
  pinned.delete(thread);
  thread.removeAttribute(PIN_LIVE_ATTR);
  clear(was);
  const held = was.painted ?? was.x - was.cap;
  if (!was.live.isConnected || Math.abs(held) < 0.5) return undefined;
  // Drawn `held` short of where the thread draws it now (its layout place when the cap is 0).
  return { id: LIVE_THINKING, y: held, used: false };
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
  if (!(ms > 0)) return;
  const timed = { duration: ms, easing };
  row.animate([{ translate: `0 ${-carry.y}px` }, { translate: "0 0" }], timed);
  // Played home from up over the rows above it, each of them is clipped where the line's drawn top
  // passes, on the same clock: the overlap is `bottom - top + offset`, linear in the line's offset, so
  // the clip's two keyframes match it on every frame (a negative inset clips nothing).
  if (carry.y <= 0) return;
  const top = row.offsetTop;
  for (const { row: above, bottom } of rowsAbove(row, carry.y)) {
    const from = bottom - top + carry.y;
    if (from <= 0.25) continue;
    above.animate(
      [{ clipPath: clipBottom(Math.ceil(from)) }, { clipPath: clipBottom(Math.floor(bottom - top)) }],
      timed,
    );
  }
}

const clipBottom = (px: number) => `inset(-4096px -4096px ${px}px -4096px)`;
