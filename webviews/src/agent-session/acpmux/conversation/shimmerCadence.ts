const ACTIVE_CLASS = "is-shimmer-active";
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

/** Each visible label gets a one-second CSS sweep, then rests for three seconds. */
export function startShimmerCadence(element: HTMLElement): () => void {
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

  const stop = () => {
    running = false;
    window.clearTimeout(initial);
    window.clearTimeout(active);
    window.clearInterval(interval);
    initial = active = interval = undefined;
    element.classList.remove(ACTIVE_CLASS);
  };
  const sweep = () => {
    element.classList.add(ACTIVE_CLASS);
    active = window.setTimeout(() => {
      element.classList.remove(ACTIVE_CLASS);
      active = undefined;
    }, 1000);
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
    if (next === running) return;
    if (!next) return stop();
    running = true;
    initial = window.setTimeout(() => {
      initial = undefined;
      sweep();
      interval = window.setInterval(sweep, 4000);
    }, 600);
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
