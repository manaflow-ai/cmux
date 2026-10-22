// SYNCED-SPINNERS (user 2026-10-20: "make sure spinners are synced and spinning in the same
// direction"). Every page spinner runs the `cmux-spin` keyframes (desktop.css: clockwise, one
// `--cmux-spinner-period`), and this clock pins each one's phase to Unix time mod its period, the
// same time base the native spinners use (CmuxNextDesign `SpinnerClock`). Two spinners, in one page,
// two pages or a page and the app chrome, then sit at the same angle at the same moment.

/** The keyframes every page spinner runs (desktop.css). */
export const SPINNER_KEYFRAMES = "cmux-spin";
/** Every shared loop the clock keeps in phase: the spinner, and agent work's breathing dot and
 * shimmer (WORKING-LOOK, desktop.css), so many working rows move as one. */
export const SHARED_LOOP_KEYFRAMES: ReadonlySet<string> = new Set([
  SPINNER_KEYFRAMES,
  "cmux-breathe",
  "cmux-shimmer",
  // The Thinking shimmer's two layers (ShimmerText.tsx): one phase keeps the lit words still.
  "cmux-shimmer-band",
  "cmux-shimmer-lit",
]);

/** The start time (document timeline ms) a loop of `period` ms must have so that its phase at
 * `timelineNow` is (Unix ms) mod `period`. `timeOrigin` is `performance.timeOrigin`, the Unix ms at
 * which the document timeline reads 0. */
export function spinnerStartTime(timelineNow: number, timeOrigin: number, period: number): number {
  if (!(period > 0)) return timelineNow;
  const unixNow = timeOrigin + timelineNow;
  const phase = ((unixNow % period) + period) % period;
  return timelineNow - phase;
}

/** The bits of a CSS animation the clock reads and sets (a test passes a plain object). */
export type SpinnerAnimation = {
  animationName?: string;
  startTime: CSSNumberish | null;
  effect: { getTiming(): { duration?: number | string | CSSNumericValue } } | null;
};

/** Moves `animation` onto the shared phase when it runs shared loop keyframes; true if it did. */
export function alignSpinner(animation: SpinnerAnimation, timelineNow: number, timeOrigin: number): boolean {
  if (!animation.animationName || !SHARED_LOOP_KEYFRAMES.has(animation.animationName)) return false;
  const duration = animation.effect?.getTiming().duration;
  if (typeof duration !== "number" || !(duration > 0)) return false;
  animation.startTime = spinnerStartTime(timelineNow, timeOrigin, duration);
  return true;
}

const installed = new WeakSet<Document>();

/** Aligns every spinner that starts in `doc` from now on (once per document). Reduced motion runs no
 * spinner animation, so there is nothing to align. */
export function installSpinnerClock(doc: Document = document): void {
  if (installed.has(doc)) return;
  installed.add(doc);
  doc.addEventListener(
    "animationstart",
    (event) => {
      if (!SHARED_LOOP_KEYFRAMES.has(event.animationName) || !(event.target instanceof Element)) return;
      const now = doc.timeline?.currentTime;
      const origin = doc.defaultView?.performance.timeOrigin;
      if (typeof now !== "number" || typeof origin !== "number") return;
      // `subtree` reaches a spinner drawn on a pseudo-element (`#status::before`).
      for (const animation of event.target.getAnimations({ subtree: true })) {
        alignSpinner(animation as unknown as SpinnerAnimation, now, origin);
      }
    },
    true,
  );
}
