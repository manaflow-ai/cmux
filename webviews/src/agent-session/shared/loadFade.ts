// Blank to text is a fast fade, not a pop (Leo, 2026-11-07, ask-69299b9711: "going from blank to
// text is more jarring than blank to fast fade in to text. Obviously the ideal is, you know, even on
// restart, you just load in and it's just fast, but sometimes you just can't achieve it. If you
// can't achieve it, that's the current fallback."). Loading at once stays the goal: what a view has
// at its first paint draws whole and never fades. Only what arrives after a blank (or partly blank)
// first paint, while the view still loads or just after, fades in once, opacity only, so nothing
// moves and no height changes. The class (`LOAD_FADE_CLASS`, pages/shared/desktop.css) plays the
// host's fade-in token (`--agent-motion-in`, the motion scale's micro step): Reduce Motion and motion
// off draw the final state at once. No timer, observer or frame loop: a window that closes on the
// clock and a class whose animation ends on its own.
import { useState } from "react";
import { entranceAllowed } from "./pageReveal";

/** The class that fades a block in once (pages/shared/desktop.css `cmux-load-fade`). */
export const LOAD_FADE_CLASS = "cmux-load-fade";

/// How long after the view's load ends (its read landed) content that arrives still counts as part
/// of the load: a second chunk right after the first fades as the first did. Past it, arrivals are
/// live and take their own entrance (or none).
export const LOAD_FADE_WINDOW_MS = 600; // motion-allow: how long arrivals count as the load, not an animation

/// How soon after it arrived an item must mount to fade. An item that arrived off screen and mounts
/// later, because the reader scrolled to it, is history drawn in place and never fades.
export const LOAD_FADE_MOUNT_MS = 250; // motion-allow: an arrival-to-mount bound, not an animation

/// The load phase of one keyed view (the chat transcript's rows): which items arrived while it
/// loaded, so their first mount fades. O(1) per item; it holds only the ids that arrived in the
/// window and lets them all go when the window closes.
export class LoadFadeWindow {
  #loading = false;
  #until = Number.NEGATIVE_INFINITY;
  readonly #arrived = new Map<string, number>();
  readonly #now: () => number;

  constructor(now: () => number = () => performance.now()) {
    this.#now = now;
  }

  /// Called on each render with whether the view still loads. The window is open while it loads
  /// and for `LOAD_FADE_WINDOW_MS` after it stops; a closed window drops every id it held.
  phase(loading: boolean): void {
    const now = this.#now();
    if (loading) {
      this.#loading = true;
      this.#until = Number.POSITIVE_INFINITY;
    } else if (this.#loading) {
      this.#loading = false;
      this.#until = now + LOAD_FADE_WINDOW_MS;
    }
    if (now > this.#until && this.#arrived.size > 0) this.#arrived.clear();
  }

  /// Whether what arrives now is part of the load (and the page may run an entrance).
  get open(): boolean {
    return this.#now() <= this.#until && entranceAllowed();
  }

  /// Item `id` arrived in the open window.
  arrive(id: string): void {
    this.#arrived.set(id, this.#now());
  }

  /// Whether item `id`, mounting now for the first time, fades in. Pure: the frame consumes it with
  /// `shown` after it mounts, so a StrictMode double render reads the same answer.
  fades(id: string): boolean {
    const at = this.#arrived.get(id);
    return at !== undefined && this.#now() - at <= LOAD_FADE_MOUNT_MS;
  }

  /// Item `id` mounted: a later remount (scrolled out and back) draws it whole.
  shown(id: string): void {
    this.#arrived.delete(id);
  }

  /// A new view (another chat): nothing of the last one fades.
  clear(): void {
    this.#arrived.clear();
    this.#loading = false;
    this.#until = Number.NEGATIVE_INFINITY;
  }
}

/// For one block that loads (a list's body, a card's text): whether its content, shown now, came
/// after a blank first paint and so fades in once. Content ready at the block's first render never
/// fades; neither does any later change once the content has shown.
export function useLoadFade(ready: boolean): boolean {
  const [phase, setPhase] = useState<"blank" | "shown" | "fade">(ready ? "shown" : "blank");
  if (phase === "blank" && ready) {
    const next = entranceAllowed() ? "fade" : "shown";
    setPhase(next);
    return next === "fade";
  }
  return phase === "fade";
}
