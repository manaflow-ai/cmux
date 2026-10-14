// Scroll motion for the thread minimap: a JS-driven scroll on a cubic-bezier curve (the browser's
// smooth scroll cannot take a curve), the landing highlight on a prompt's bubble, and the Reduce
// Motion check both use. One scroll runs per scroller; the reader's own wheel, touch, pointer or key
// ends it where it is.
import { bezierAt, type CubicBezier } from "../../../ui/cubicBezier";
import { HIGHLIGHT_EASING, HIGHLIGHT_MS } from "./model";

const running = new WeakMap<HTMLElement, () => void>();
const READER_INPUTS = ["wheel", "pointerdown", "touchstart", "keydown"] as const;

/// Reduce Motion: the system's, or the app's (its motion tokens are 0 when Reduce Motion is on or
/// ui.animationSpeed is off; AgentPaneTheme.motion).
export function reducedMotion(): boolean {
  if (globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return true;
  try {
    const value = getComputedStyle(document.documentElement).getPropertyValue("--agent-motion-in").trim();
    return value === "0s" || value === "0ms";
  } catch {
    return false;
  }
}

/// Ends the scroll running on `node`, if any, where it is.
export function stopScroll(node: HTMLElement): void {
  running.get(node)?.();
}

/// Scrolls `node` to `target()` over `duration` ms on `curve`. The target is read each frame, so rows
/// that measure meanwhile move the landing with them. A zero duration jumps.
export function animateScroll(node: HTMLElement, target: () => number, duration: number, curve: CubicBezier): void {
  stopScroll(node);
  if (duration <= 0 || typeof requestAnimationFrame !== "function") {
    node.scrollTop = target();
    return;
  }
  const from = node.scrollTop;
  const start = performance.now();
  let frame = 0;
  const end = () => {
    cancelAnimationFrame(frame);
    for (const name of READER_INPUTS) node.removeEventListener(name, end);
    if (running.get(node) === end) running.delete(node);
  };
  const step = (now: number) => {
    const progress = Math.min(1, Math.max(0, (now - start) / duration));
    node.scrollTop = from + (target() - from) * bezierAt(curve, progress);
    if (progress < 1) frame = requestAnimationFrame(step);
    else end();
  };
  for (const name of READER_INPUTS) node.addEventListener(name, end, { passive: true });
  running.set(node, end);
  frame = requestAnimationFrame(step);
}

/// The landing highlight: the bubble's background starts at `--acpmux-landing-highlight` and eases
/// back to its own over HIGHLIGHT_MS. None under Reduce Motion.
export function highlightBubble(bubble: HTMLElement | null | undefined): void {
  if (!bubble || typeof bubble.animate !== "function" || reducedMotion()) return;
  const style = getComputedStyle(bubble);
  const highlight = style.getPropertyValue("--acpmux-landing-highlight").trim();
  if (!highlight) return;
  for (const animation of bubble.getAnimations?.() ?? []) if (animation.id === "acpmux-landing") animation.cancel();
  const animation = bubble.animate(
    [
      { backgroundColor: highlight },
      { backgroundColor: highlight, offset: 0.35 },
      { backgroundColor: style.backgroundColor },
    ],
    { duration: HIGHLIGHT_MS, easing: HIGHLIGHT_EASING },
  );
  animation.id = "acpmux-landing";
}
