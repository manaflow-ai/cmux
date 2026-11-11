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

/** On an element whose loops took the shared phase from a negative delay at mount (`setLoopPhase`): its
 * loops' delay is that phase, not an offset of their own, so a later alignment counts it in. */
export const LOOP_PHASE_ATTRIBUTE = "data-cmux-loop-phase";

/** The bits of a CSS animation the clock reads and sets (a test passes a plain object). */
export type SpinnerAnimation = {
  animationName?: string;
  startTime: CSSNumberish | null;
  effect: {
    getTiming(): { duration?: number | string | CSSNumericValue; delay?: number };
    target?: Element | null;
  } | null;
};

/** Moves `animation` onto the shared phase when it runs shared loop keyframes; true if it did. A loop's own
 * delay stays an offset from the shared phase (the running wave's place, the mic's staggered dots), except
 * under `LOOP_PHASE_ATTRIBUTE`, where the delay was the phase itself and is taken out again. */
export function alignSpinner(animation: SpinnerAnimation, timelineNow: number, timeOrigin: number): boolean {
  if (!animation.animationName || !SHARED_LOOP_KEYFRAMES.has(animation.animationName)) return false;
  const timing = animation.effect?.getTiming();
  const duration = timing?.duration;
  if (typeof duration !== "number" || !(duration > 0)) return false;
  const phased = animation.effect?.target?.closest?.(`[${LOOP_PHASE_ATTRIBUTE}]`);
  const delay = phased && typeof timing?.delay === "number" ? timing.delay : 0;
  animation.startTime = spinnerStartTime(timelineNow, timeOrigin, duration) - delay;
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

/** The variable that holds the shimmer loops' period (desktop.css), which `setLoopPhase` reads once a page. */
export const SHIMMER_PERIOD_VARIABLE = "--cmux-shimmer-period";
/** The variable `setLoopPhase` writes: the loops under the element take it as their `animation-delay`. */
export const LOOP_DELAY_VARIABLE = "--cmux-loop-delay";

const periods = new WeakMap<Document, Map<string, number>>();

/** A CSS time (`2.8s`, `2800ms`) in ms, or undefined. */
export function cssTimeMs(value: string): number | undefined {
  const match = /^\s*(-?[\d.]+)(ms|s)\s*$/.exec(value);
  if (!match) return undefined;
  const ms = Number(match[1]) * (match[2] === "s" ? 1000 : 1);
  return ms > 0 ? ms : undefined;
}

/** `variable`'s period on `doc`'s root, read once per page: nothing changes it after load. */
function periodOf(doc: Document, variable: string): number | undefined {
  let byName = periods.get(doc);
  if (!byName) periods.set(doc, (byName = new Map()));
  if (!byName.has(variable)) {
    const view = doc.defaultView;
    const ms = view ? cssTimeMs(view.getComputedStyle(doc.documentElement).getPropertyValue(variable)) : undefined;
    if (ms === undefined) return undefined;
    byName.set(variable, ms);
  }
  return byName.get(variable);
}

/** Puts the shared loops under `element` on the shared phase on the frame they mount: a loop that mounts
 * again (a running line the transcript brings back into view as the reader scrolls) otherwise paints its
 * first frame at phase 0, and `animationstart` moves it a frame later, a blink (Leo, 2026-11-03: "not
 * flicker EVER when im scrolling"). It writes the phase as a negative delay (`LOOP_DELAY_VARIABLE`, which
 * the loops' rules read) from the period cached per page, and reads no style: asking the element for its
 * animations flushed style on every running row's mount, about 8% of a streaming chat's main thread on
 * Leo's Mac (2026-11-11). */
/// `at` is when the loops start, in the document's ms (`performance.now()`): the mount by default, or an
/// `animationstart`'s time when they start again later (below).
export function setLoopPhase(element: HTMLElement, variable = SHIMMER_PERIOD_VARIABLE, at?: number): void {
  const doc = element.ownerDocument;
  const period = periodOf(doc, variable);
  const view = doc.defaultView;
  if (period === undefined || !view) return;
  const unixAt = view.performance.timeOrigin + (at ?? view.performance.now());
  const phase = ((unixAt % period) + period) % period;
  const delay = `-${phase.toFixed(1)}ms`;
  element.setAttribute(LOOP_PHASE_ATTRIBUTE, "");
  // The same delay again (a row's band and lit copy start in one frame) changes nothing: no style write.
  if (element.style.getPropertyValue(LOOP_DELAY_VARIABLE) !== delay)
    element.style.setProperty(LOOP_DELAY_VARIABLE, delay);
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
      // A loop phased by its delay (`setLoopPhase`) starts again whenever its rule comes back (an ancestor
      // shown again, the static status look or the motion gate turned off): its delay is written anew for
      // the time it started, still with no style read. The mount's own start writes the same phase.
      const phased = event.target.closest(`[${LOOP_PHASE_ATTRIBUTE}]`);
      if (phased instanceof HTMLElement) return setLoopPhase(phased, SHIMMER_PERIOD_VARIABLE, event.timeStamp);
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
