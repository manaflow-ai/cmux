// RUNNING-WAVE (Leo 2026-10-21: "these glimmer at different intervals ... it would look cool if they
// went in a wave, like how thinking glimmers in ChatGPT"). Running indicators side by side share one
// shimmer that sweeps across them, left to right (top to bottom for stacked rows): each running item
// carries the `acpmux-wave-item` class and its place in the wave (`--wave-index`), and wave.css turns
// the index into a phase offset of the one `cmux-wave` loop. Every item's loop starts on one epoch
// (Unix time mod the period, the spinners' clock, ui/spinnerClock.ts), so items that mount at
// different moments still line up and the offsets alone make the wave. Finished and failed items get
// no index and stay still; Reduce Motion, the app's motion gate (`data-cmux-motion`), static status
// indicators and a hidden page stop it.
import type { CSSProperties } from "react";
import { PAGE_HIDDEN_ATTRIBUTE, spinnerStartTime, type SpinnerAnimation } from "./spinnerClock";

/** The class every running indicator in a wave carries. */
export const WAVE_CLASS = "acpmux-wave-item";
/** The keyframes of the wave (wave.css). */
export const WAVE_KEYFRAMES = "cmux-wave";
/** On `<html>` while the page is hidden: the wave stops, and starts again in phase when it shows
 * (the spinner clock realigns it, ui/spinnerClock.ts). */
export { PAGE_HIDDEN_ATTRIBUTE };

/** Each item's place in the wave, in display order: consecutive indices for the items that `live`
 * says are running, undefined for the rest (finished, failed), so the wave skips them. */
export function waveIndices<T>(items: readonly T[], live: (item: T) => boolean): (number | undefined)[] {
  let next = 0;
  return items.map((item) => (live(item) ? next++ : undefined));
}

/** The class and style an item at `index` in the wave takes; nothing for an item outside it. */
export function waveProps(index: number | undefined): { className?: string; style?: CSSProperties } {
  if (index === undefined) return {};
  return { className: WAVE_CLASS, style: { "--wave-index": index } as CSSProperties };
}

/** Moves a `cmux-wave` loop onto the one shared start (the epoch); true if it did. Its own delay
 * (the index offset) is left alone. */
export function alignWave(animation: SpinnerAnimation, timelineNow: number, timeOrigin: number): boolean {
  if (animation.animationName !== WAVE_KEYFRAMES) return false;
  const duration = animation.effect?.getTiming().duration;
  if (typeof duration !== "number" || !(duration > 0)) return false;
  animation.startTime = spinnerStartTime(timelineNow, timeOrigin, duration);
  return true;
}

const installed = new WeakSet<Document>();

/** Once per document: every wave loop that starts takes the shared start, and `<html>` is marked
 * while the page is hidden (`visibilityState`) so no wave runs unseen. Showing it again resumes the
 * loops, and the spinner clock puts them back on the shared start (`realignSpinners`). */
export function installWave(doc: Document = document): void {
  if (installed.has(doc)) return;
  installed.add(doc);
  const sync = () => doc.documentElement.toggleAttribute(PAGE_HIDDEN_ATTRIBUTE, doc.visibilityState === "hidden");
  sync();
  doc.addEventListener("visibilitychange", sync);
  doc.addEventListener(
    "animationstart",
    (event) => {
      if (event.animationName !== WAVE_KEYFRAMES || !(event.target instanceof Element)) return;
      // Hidden, the loop stays paused; the spinner clock aligns it when the page shows.
      if (doc.documentElement.hasAttribute(PAGE_HIDDEN_ATTRIBUTE)) return;
      const now = doc.timeline?.currentTime;
      const origin = doc.defaultView?.performance.timeOrigin;
      if (typeof now !== "number" || typeof origin !== "number") return;
      for (const animation of event.target.getAnimations()) {
        alignWave(animation as unknown as SpinnerAnimation, now, origin);
      }
    },
    true,
  );
}
