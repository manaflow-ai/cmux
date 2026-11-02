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
  // The running wave (ui/wave.ts): its own delay (the item's place in the wave) stays as it is.
  "cmux-wave",
]);

/** On `<html>` while the page is hidden (ui/wave.ts sets it): every loop is paused (desktop.css). */
export const PAGE_HIDDEN_ATTRIBUTE = "data-cmux-page-hidden";

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

/** Puts every shared loop running in `doc` back on the shared phase; the count it moved. A loop
 * paused while the page was hidden resumes where it stopped, not where the clock is, and no
 * `animationstart` fires for it, so without this every spinner already on a page shown again sat
 * out of step with the ones mounted after it (Leo 2026-11-01, on two working spinners side by side:
 * "why did you desync these"). */
export function realignSpinners(doc: Document = document): number {
  const now = doc.timeline?.currentTime;
  const origin = doc.defaultView?.performance.timeOrigin;
  if (typeof now !== "number" || typeof origin !== "number") return 0;
  let moved = 0;
  // `getAnimations` flushes style first, so loops the cleared attribute resumed are running here.
  for (const animation of doc.getAnimations()) {
    if (animation.playState === "paused") continue;
    if (alignSpinner(animation as unknown as SpinnerAnimation, now, origin)) moved += 1;
  }
  return moved;
}

const installed = new WeakSet<Document>();

/** Aligns every spinner that starts in `doc` from now on, and every one already running when the
 * page shows again (once per document). Reduced motion runs no spinner animation, so there is
 * nothing to align. */
export function installSpinnerClock(doc: Document = document): void {
  if (installed.has(doc)) return;
  installed.add(doc);
  const root = doc.documentElement;
  doc.addEventListener(
    "animationstart",
    (event) => {
      if (!SHARED_LOOP_KEYFRAMES.has(event.animationName) || !(event.target instanceof Element)) return;
      // A hidden page's loops stay paused: giving one a start time would run it unseen. They take
      // the shared phase when the page shows (below).
      if (root.hasAttribute(PAGE_HIDDEN_ATTRIBUTE)) return;
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
  const MutationObserverClass = doc.defaultView?.MutationObserver;
  if (!MutationObserverClass) return;
  new MutationObserverClass((records) => {
    const shown = records.some((record) => record.oldValue !== null) && !root.hasAttribute(PAGE_HIDDEN_ATTRIBUTE);
    if (shown) realignSpinners(doc);
  }).observe(root, { attributes: true, attributeFilter: [PAGE_HIDDEN_ATTRIBUTE], attributeOldValue: true });
}
