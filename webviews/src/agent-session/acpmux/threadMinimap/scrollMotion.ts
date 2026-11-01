// Scroll motion for the thread minimap: a JS-driven scroll on a cubic-bezier curve (the browser's
// smooth scroll cannot take a curve), the landing highlight on a prompt's bubble, and the Reduce
// Motion check both use. One scroll runs per scroller; the reader's own wheel, touch, pointer or key
// ends it where it is.
import { bezierAt, type CubicBezier } from "../../../ui/cubicBezier";
import { HIGHLIGHT_EASING, HIGHLIGHT_MS } from "./model";
import { railOwnsWheel } from "./railWheel";
import { userScrollIntent } from "../conversation/userScroll";

const running = new WeakMap<HTMLElement, () => void>();

/// Sent (not bubbling) on a scroller right after this module's motion writes its offset from a frame
/// callback. The browser's own `scroll` event for that write comes on the next frame, after this one
/// paints, so what must move with the scroll on its own frame (the minimap's band) listens for this too.
export const MOTION_SCROLL_EVENT = "acpmux-motion-scroll";

/// Tells `node`'s listeners that the motion just moved it (`MOTION_SCROLL_EVENT`).
function announceScroll(node: HTMLElement): void {
  // A stand-in scroller (a unit test's) may have no document or events of its own.
  if (typeof node.dispatchEvent !== "function") return;
  const Event_ = node.ownerDocument?.defaultView?.Event ?? globalThis.Event;
  if (Event_) node.dispatchEvent(new Event_(MOTION_SCROLL_EVENT));
}
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
  options: { explicit?: boolean } = {},
): void {
  const intent = userScrollIntent(node);
  if (intent.isHeld() && !options.explicit) return;
  stopScroll(node);
  const from = node.scrollTop;
  runScroll(
    node,
    duration,
    curve,
    (progress) => {
      node.scrollTop = from + (target() - from) * progress;
    },
    then,
    cancelled,
    false,
    options.explicit,
  );
}

/// An explicit mouse-wheel distance on the same clock as jumps. Each step adds only its own delta
/// to the live offset: the existing row-id anchor owns layout/prepend corrections. A notch headed
/// to the bottom follows that moving end; one parked in history keeps exactly its wheel distance.
export function animateScrollBy(
  node: HTMLElement,
  distance: number,
  duration: number,
  curve: CubicBezier,
  toEnd: boolean,
  finished: () => void,
): { remaining(): number } {
  let done = 0;
  let previous = 0;
  const left = () => (toEnd ? Math.max(0, node.scrollHeight - node.clientHeight - node.scrollTop) : distance - done);
  runScroll(
    node,
    duration,
    curve,
    (progress) => {
      const fraction = previous === 1 ? 1 : (progress - previous) / (1 - previous);
      // Quantize only cumulative mouse-wheel travel. Each incremental write is a whole pixel,
      // so WebKit cannot floor a fractional tail past the target and bounce back. The live
      // offset (including the row-id anchor's own corrections) is never rounded or replaced.
      const next = Math.round(distance * progress);
      node.scrollTop += toEnd ? left() * fraction : next - done;
      done = next;
      previous = progress;
    },
    finished,
    finished,
    true,
  );
  return { remaining: left };
}

/// One owner, clock and cleanup path for both jumps and notches. Ordinary rides yield to held user
/// intent and subscribe to its end signal. Wheel rides are explicit and intentionally bypass that
/// subscription: the wheel installer owns native-wheel versus notch arbitration and cancellation.
function runScroll(
  node: HTMLElement,
  duration: number,
  curve: CubicBezier,
  write: (progress: number) => void,
  then?: () => void,
  cancelled?: () => void,
  wheel = false,
  explicit = false,
): void {
  const intent = wheel ? undefined : userScrollIntent(node);
  if (intent?.isHeld() && !explicit) return;
  stopScroll(node);
  if (duration <= 0 || typeof requestAnimationFrame !== "function") {
    write(1);
    then?.();
    return;
  }
  const doc = node.ownerDocument;
  const owner = wheel ? (doc.defaultView ?? node) : node;
  const inputs = wheel ? READER_INPUTS.filter((input) => input !== "wheel") : READER_INPUTS;
  const start = performance.now();
  let frame = 0;
  let active = true;
  let unsubscribeIntent: (() => void) | undefined;
  const hidden = () => {
    if (doc.hidden) end();
  };
  const cleanup = () => {
    active = false;
    cancelAnimationFrame(frame);
    for (const name of inputs) owner.removeEventListener(name, end, wheel);
    if (wheel) doc.removeEventListener("visibilitychange", hidden);
    unsubscribeIntent?.();
    if (running.get(node) === end) running.delete(node);
  };
  const end = () => {
    if (!active) return;
    cleanup();
    cancelled?.();
  };
  if (intent) unsubscribeIntent = intent.subscribe(end);
  const step = (now: number) => {
    if (wheel && (doc.hidden || node.clientHeight === 0)) {
      end();
      return;
    }
    const progress = Math.min(1, Math.max(0, (now - start) / duration));
    write(bezierAt(curve, progress));
    announceScroll(node);
    if (!active) return;
    if (progress < 1) frame = requestAnimationFrame(step);
    else {
      cleanup();
      then?.();
    }
  };
  for (const name of inputs) owner.addEventListener(name, end, { capture: wheel, passive: true });
  if (wheel) doc.addEventListener("visibilitychange", hidden);
  running.set(node, end);
  frame = requestAnimationFrame(step);
}

/// Holds a jump's landing while the rows it crossed mount and measure: each frame, `offset()` says
/// how far the target sits from where it should land (undefined while it is not mounted), and the
/// scroll moves by that much, until it holds for three frames or `frames` run out. Any input anywhere
/// in the page (a wheel, a press, a key: the reader scrolling, Find, Jump to Latest) or another scroll
/// on `node` ends it. A wheel over a rail that scrolls itself is not the reader's (railWheel.ts): the
/// rail moves, and the landing goes on.
export function settleScroll(
  node: HTMLElement,
  offset: () => number | undefined,
  frames: number,
  options: { explicit?: boolean } = {},
): void {
  const intent = userScrollIntent(node);
  if (intent.isHeld() && !options.explicit) return;
  stopScroll(node);
  if (typeof requestAnimationFrame !== "function") return;
  let frame = 0;
  let left = frames;
  let steady = 0;
  const page = node.ownerDocument.defaultView ?? window;
  let unsubscribeIntent: (() => void) | undefined;
  const end = () => {
    cancelAnimationFrame(frame);
    for (const name of READER_INPUTS) page.removeEventListener(name, input, true);
    unsubscribeIntent?.();
    if (running.get(node) === end) running.delete(node);
  };
  const input = (event: Event) => {
    if (!railOwnsWheel(event)) end();
  };
  unsubscribeIntent = intent.subscribe(end);
  const step = () => {
    // A scroller with no layout (hidden, or a DOM without one) has nothing to measure.
    const by = node.clientHeight > 0 ? offset() : undefined;
    if (by !== undefined) {
      const max = Math.max(0, node.scrollHeight - node.clientHeight);
      const to = Math.max(0, Math.min(max, node.scrollTop + by));
      if (Math.abs(to - node.scrollTop) > 0.5) {
        node.scrollTop = to;
        announceScroll(node);
        steady = 0;
      } else steady += 1;
    }
    left -= 1;
    if (steady >= 3 || left <= 0) end();
    else frame = requestAnimationFrame(step);
  };
  // Captured on the window: added during the input that started the jump, it does not see that one.
  for (const name of READER_INPUTS) page.addEventListener(name, input, { capture: true, passive: true });
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
