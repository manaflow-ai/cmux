const ACTIVE_CLASS = "is-shimmer-active";
const CONTINUOUS_CLASS = "is-shimmer-continuous";
const observers = new WeakMap<
  Document,
  {
    observer: IntersectionObserver;
    targets: Map<Element, (visible: boolean) => void>;
  }
>();

function observeVisibility(element: HTMLElement, onVisible: (visible: boolean) => void) {
  const document = element.ownerDocument;
  const Observer = document.defaultView?.IntersectionObserver;
  if (!Observer) {
    onVisible(true);
    return () => {};
  }
  let shared = observers.get(document);
  if (!shared) {
    const targets = new Map<Element, (visible: boolean) => void>();
    const observer = new Observer((entries) => {
      for (const entry of entries) targets.get(entry.target)?.(entry.isIntersecting);
    });
    shared = { observer, targets };
    observers.set(document, shared);
  }
  shared.targets.set(element, onVisible);
  shared.observer.observe(element);
  return () => {
    shared.targets.delete(element);
    shared.observer.unobserve(element);
    if (shared.targets.size === 0) {
      shared.observer.disconnect();
      observers.delete(document);
    }
  };
}

/** When a label's sweeps run: the first `firstMs` after it shows, then one every `everyMs`, each `sweepMs` long. */
export type ShimmerCadence = { firstMs: number; sweepMs: number; everyMs: number };

/** The shipped cadence: a one-second sweep every four seconds (`--cv-shimmer-sweep-duration`, 1s). */
export const DEFAULT_SHIMMER_CADENCE: ShimmerCadence = { firstMs: 600, sweepMs: 1000, everyMs: 4000 };

/** A look's continuous pass (thinkingLook.ts `shimmer: "continuous"`): its period in ms, or undefined
 * for the default cadence. The period is the root's `--cv-shimmer-period`. */
function continuousPeriod(root: HTMLElement): number | undefined {
  if (root.dataset.thinkingShimmer !== "continuous") return undefined;
  const period = Number.parseFloat(root.style.getPropertyValue("--cv-shimmer-period"));
  return Number.isFinite(period) && period > 0 ? period : 1250;
}

/** Each visible label gets a one-second CSS sweep, then rests for three seconds. A `cadence` other than
 * the default (the pacing gallery's candidates, ShimmerPacing.gallery.tsx) also sets the sweep's CSS
 * duration on the label, so the class and the animation end together. Under a look's continuous
 * shimmer the sweep instead loops in CSS with no rest, every label on one wall-clock phase (a negative
 * delay from `Date.now()`), so the live line and the running rows sweep together; this sets no timer then. */
export function startShimmerCadence(element: HTMLElement, cadence = DEFAULT_SHIMMER_CADENCE): () => void {
  const { firstMs, sweepMs, everyMs } = cadence;
  if (cadence !== DEFAULT_SHIMMER_CADENCE) element.style.setProperty("--cv-shimmer-sweep-duration", `${sweepMs}ms`);
  const document = element.ownerDocument;
  const window = document.defaultView;
  if (!window) return () => {};
  const root = document.documentElement;
  const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)");
  let visible = false;
  let running = false;
  let initial: number | undefined;
  let active: number | undefined;
  let interval: number | undefined;
  let runningPeriod: number | undefined;

  const stop = () => {
    running = false;
    window.clearTimeout(initial);
    window.clearTimeout(active);
    window.clearInterval(interval);
    initial = active = interval = undefined;
    element.classList.remove(ACTIVE_CLASS, CONTINUOUS_CLASS);
    element.style.removeProperty("--cv-shimmer-delay");
    runningPeriod = undefined;
  };
  const sweep = () => {
    element.classList.add(ACTIVE_CLASS);
    active = window.setTimeout(() => {
      element.classList.remove(ACTIVE_CLASS);
      active = undefined;
    }, sweepMs);
  };
  const update = () => {
    const blocked =
      document.hidden ||
      root.hasAttribute("data-cmux-page-hidden") ||
      reducedMotion?.matches ||
      root.dataset.reducedMotion === "true" ||
      root.dataset.statusIndicators === "static" ||
      [root.dataset.cmuxMotion, root.dataset.agentMotion].some((motion) => motion === "off" || motion === "reduced");
    const next = visible && !blocked;
    const period = continuousPeriod(root);
    if (next === running && period === runningPeriod) return;
    stop();
    if (!next) return;
    running = true;
    runningPeriod = period;
    if (period !== undefined) {
      element.style.setProperty("--cv-shimmer-delay", `${-(Date.now() % period)}ms`);
      element.classList.add(CONTINUOUS_CLASS);
      return;
    }
    initial = window.setTimeout(() => {
      initial = undefined;
      sweep();
      interval = window.setInterval(sweep, everyMs);
    }, firstMs);
  };
  const unobserve = observeVisibility(element, (intersecting) => {
    visible = intersecting;
    update();
  });
  const mutations = new window.MutationObserver(update);
  mutations.observe(root, {
    attributes: true,
    attributeFilter: [
      "data-reduced-motion",
      "data-status-indicators",
      "data-cmux-motion",
      "data-agent-motion",
      "data-cmux-page-hidden",
      "data-thinking-shimmer",
      // The continuous period (`--cv-shimmer-period`) lives in the root's style.
      "style",
    ],
  });
  document.addEventListener("visibilitychange", update);
  reducedMotion?.addEventListener("change", update);
  return () => {
    unobserve();
    mutations.disconnect();
    document.removeEventListener("visibilitychange", update);
    reducedMotion?.removeEventListener("change", update);
    stop();
  };
}
