// How much a primitive in ui/motion may move right now. One reading for every primitive here, so a
// sliding indicator, a view swap and the depth layer agree: the host's motion switch
// (`data-agent-motion` / `data-cmux-motion` on the root, a zero `--agent-motion-in` token), Reduce
// Motion, and a hidden page.

export type MotionMode = "full" | "reduced" | "none";

/** "none": animations are off or the page is hidden; "reduced": Reduce Motion; else "full". */
export function motionMode(
  doc: Document | undefined = typeof document === "undefined" ? undefined : document,
): MotionMode {
  const root = doc?.documentElement;
  const view = doc?.defaultView;
  if (!doc || !root || !view) return "none";
  if (doc.visibilityState === "hidden") return "none";
  if (root.dataset.agentMotion === "off" || root.dataset.cmuxMotion === "off") return "none";
  const token = view.getComputedStyle(root).getPropertyValue("--agent-motion-in").trim();
  if (token && !(Number.parseFloat(token) > 0)) return "none";
  if (root.dataset.agentMotion === "reduced" || root.dataset.cmuxMotion === "reduced") return "reduced";
  if (view.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return "reduced";
  return "full";
}

/**
 * The one spring as a Web Animations easing, or the ease-out where the engine has no `linear()`
 * easing (WebKit before Safari 17.2, which macOS 14.0 and 14.1 ship): there `animate()` throws on it.
 */
export function springEasing(
  spring: string,
  fallback: string,
  doc: Document | undefined = typeof document === "undefined" ? undefined : document,
): string {
  const supports = (doc?.defaultView as (Window & typeof globalThis) | null | undefined)?.CSS?.supports;
  try {
    return supports?.("transition-timing-function", spring) ? spring : fallback;
  } catch {
    return fallback;
  }
}
