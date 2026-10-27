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
/// that measure meanwhile move the landing with them. A zero duration jumps. Replacing or cancelling
/// the ride notifies `cancelled`; a completed ride calls only `then`.
export function animateScroll(
  node: HTMLElement,
  target: () => number,
  duration: number,
  curve: CubicBezier,
  then?: () => void,
  cancelled?: () => void,
): void {
  stopScroll(node);
  if (duration <= 0 || typeof requestAnimationFrame !== "function") {
    node.scrollTop = target();
    then?.();
    return;
  }
  const from = node.scrollTop;
  const start = performance.now();
  let frame = 0;
  const cleanup = () => {
    cancelAnimationFrame(frame);
    for (const name of READER_INPUTS) node.removeEventListener(name, end);
    if (running.get(node) === end) running.delete(node);
  };
  const end = () => {
    cleanup();
    cancelled?.();
  };
  const step = (now: number) => {
    const progress = Math.min(1, Math.max(0, (now - start) / duration));
    node.scrollTop = from + (target() - from) * bezierAt(curve, progress);
    if (progress < 1) frame = requestAnimationFrame(step);
    else {
      cleanup();
      then?.();
    }
  };
  for (const name of READER_INPUTS) node.addEventListener(name, end, { passive: true });
  running.set(node, end);
  frame = requestAnimationFrame(step);
}

/// Holds a jump's landing while the rows it crossed mount and measure: each frame, `offset()` says how
/// far the target sits from where it should land (undefined while it is not mounted), and the scroll
/// moves by that much, until it holds for three frames or `frames` run out. Any input anywhere in the
/// page (a wheel, a press, a key: the reader scrolling, Find, Jump to Latest) or another scroll on
/// `node` ends it.
export function settleScroll(node: HTMLElement, offset: () => number | undefined, frames: number): void {
  stopScroll(node);
  if (typeof requestAnimationFrame !== "function") return;
  let frame = 0;
  let left = frames;
  let steady = 0;
  const page = node.ownerDocument.defaultView ?? window;
  const end = () => {
    cancelAnimationFrame(frame);
    for (const name of READER_INPUTS) page.removeEventListener(name, end, true);
    if (running.get(node) === end) running.delete(node);
  };
  const step = () => {
    // A scroller with no layout (hidden, or a DOM without one) has nothing to measure.
    const by = node.clientHeight > 0 ? offset() : undefined;
    if (by !== undefined) {
      const max = Math.max(0, node.scrollHeight - node.clientHeight);
      const to = Math.max(0, Math.min(max, node.scrollTop + by));
      if (Math.abs(to - node.scrollTop) > 0.5) {
        node.scrollTop = to;
        steady = 0;
      } else steady += 1;
    }
    left -= 1;
    if (steady >= 3 || left <= 0) end();
    else frame = requestAnimationFrame(step);
  };
  // Captured on the window: added during the input that started the jump, it does not see that one.
  for (const name of READER_INPUTS) page.addEventListener(name, end, { capture: true, passive: true });
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
