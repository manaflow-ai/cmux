// Scroll motion for the thread minimap: a JS-driven scroll on a cubic-bezier curve (the browser's
// smooth scroll cannot take a curve), the landing highlight on a prompt's bubble, and the Reduce
// Motion check both use. One scroll runs per scroller; the reader's own wheel, touch, pointer or key
// ends it where it is.
import { bezierAt, type CubicBezier } from "../../../ui/cubicBezier";
import { HIGHLIGHT_EASING, HIGHLIGHT_MS } from "./model";
import { railOwnsWheel } from "./railWheel";
import { userScrollIntent } from "../conversation/userScroll";
import { isWheelNotch } from "../wheelGlide";

const running = new WeakMap<HTMLElement, () => void>();

/// Sent (not bubbling) on a scroller right after this module's motion writes its offset from a frame
/// callback. The browser's own `scroll` event for that write comes on the next frame, after this one
/// paints, so what must move with the scroll on its own frame (the minimap's band) listens for this too.
export const MOTION_SCROLL_EVENT = "acpmux-motion-scroll";

/// Tells `node`'s listeners that a RAF-driven motion just moved it (`MOTION_SCROLL_EVENT`).
/// Never call from React layout work: transcript listeners synchronously commit visible rows.
export function announceScroll(node: HTMLElement): void {
  // A stand-in scroller (a unit test's) may have no document or events of its own.
  if (typeof node.dispatchEvent !== "function") return;
  const Event_ = node.ownerDocument?.defaultView?.Event ?? globalThis.Event;
  if (Event_) node.dispatchEvent(new Event_(MOTION_SCROLL_EVENT));
}
const READER_INPUTS = ["wheel", "pointerdown", "touchstart", "keydown"] as const;

/// The most of its curve a paced ride plays in one painted frame (and the follow chase integrates,
/// followChase.ts): a longer frame gap (a page drawing few frames, a commit that started the ride
/// inside a frame's callbacks, so its first step comes a whole frame later) counts as this long.
export const MAX_FRAME_STEP_MS = 1000 / 30;

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

/// A trackpad fling's momentum after a scroll made from code (Leo 2026-11-12: "it doesn't, like,
/// break the momentum and jump to bottom immediately"). WebKit keeps sending the fling's momentum as
/// wheel events after a write to scrollTop, and the DOM tells nothing of their phase: the next one
/// ended Jump to latest as the reader's input, let go of the latest row, and the browser glided on
/// from where the jump put the view. Momentum is a stream of wheel events a frame or so apart that
/// keep their direction and decay; the reader's next gesture comes after a pause, turns round or
/// grows. Only the stream under way as the scroll from code started is held: no listener sees it (a
/// window capture listener installed first stops it), and the view is put back where that scroll
/// put it. Its events stay uncancelable (WebKit latches a gesture's first event's handling), so the
/// pin, not preventDefault, is what keeps the view still. Passive throughout: no wheel waits on the page.
export const MOMENTUM_GAP_MS = 80;
/// The longest a fling's momentum is held, however it decays.
const MOMENTUM_MAX_MS = 4000;
type MomentumState = {
  /// The last wheel over the scroller, and its vertical delta (its direction and size).
  at: number;
  deltaY: number;
  hold?: { target: () => number; since: number; echo: boolean };
};
const momentum = new WeakMap<HTMLElement, MomentumState>();

function continuesMomentum(event: WheelEvent, last: MomentumState, now: number): boolean {
  if (now - last.at > MOMENTUM_GAP_MS || event.ctrlKey || isWheelNotch(event)) return false;
  if (!event.deltaY) return true;
  return (
    Math.sign(event.deltaY) === Math.sign(last.deltaY) && Math.abs(event.deltaY) <= Math.abs(last.deltaY) * 1.25 + 1
  );
}

/// The hold still on: momentum keeps arriving, and not for longer than any fling's.
function heldMomentum(state: MomentumState | undefined, now = performance.now()) {
  const hold = state?.hold;
  if (!state || !hold) return undefined;
  if (now - state.at > MOMENTUM_GAP_MS || now - hold.since > MOMENTUM_MAX_MS) {
    state.hold = undefined;
    return undefined;
  }
  return hold;
}

/// Watches the wheel over `node` so a scroll from code can hold the momentum under way
/// (`holdMomentum`). Install before any other wheel listener on the page's window.
export function installMomentumHold(node: HTMLElement): () => void {
  const state: MomentumState = { at: -Infinity, deltaY: 0 };
  momentum.set(node, state);
  const page = node.ownerDocument.defaultView ?? window;
  const wheel = (event: WheelEvent) => {
    if (!node.contains(event.target as Node | null)) return;
    const now = performance.now();
    if (heldMomentum(state, now)) {
      if (continuesMomentum(event, state, now)) {
        event.stopImmediatePropagation();
        state.at = now;
        if (event.deltaY) state.deltaY = event.deltaY;
        return;
      }
      state.hold = undefined;
    }
    state.at = now;
    state.deltaY = event.deltaY;
  };
  // Any other input is the reader's own: the view is theirs again.
  const release = () => {
    state.hold = undefined;
  };
  // Before the transcript's own scroll handler (capture runs first at the target): momentum that
  // moved the view moves it back, and neither that scroll nor the one the write back fires is the
  // reader's. A scroll from code still running owns the offset (its rebase absorbs the momentum).
  const scroll = (event: Event) => {
    const hold = heldMomentum(state);
    if (!hold || running.has(node)) return;
    const target = hold.target();
    if (Math.abs(node.scrollTop - target) > 0.5) {
      node.scrollTop = target;
      hold.echo = true;
      event.stopImmediatePropagation();
    } else if (hold.echo) {
      hold.echo = false;
      event.stopImmediatePropagation();
    }
  };
  page.addEventListener("wheel", wheel, { capture: true, passive: true });
  for (const name of ["pointerdown", "touchstart", "keydown"]) page.addEventListener(name, release, true);
  node.addEventListener("scroll", scroll, { capture: true, passive: true });
  return () => {
    page.removeEventListener("wheel", wheel, true);
    for (const name of ["pointerdown", "touchstart", "keydown"]) page.removeEventListener(name, release, true);
    node.removeEventListener("scroll", scroll, true);
    if (momentum.get(node) === state) momentum.delete(node);
  };
}

/// A scroll from code just moved `node` to `target()`: the momentum of a fling under way as it
/// started is held there until it ends (`installMomentumHold`). Nothing in flight, nothing held.
export function holdMomentum(node: HTMLElement, target: () => number): void {
  const state = momentum.get(node);
  const now = performance.now();
  if (!state || now - state.at > MOMENTUM_GAP_MS || !state.deltaY) return;
  state.hold = { target, since: now, echo: false };
}

/// Ends the scroll running on `node`, if any, where it is.
export function stopScroll(node: HTMLElement): void {
  running.get(node)?.();
}

/// Scrolls `node` to `target()` over `duration` ms on `curve`. The target is read each frame, so rows
/// that measure meanwhile move the landing with them. A zero duration jumps. Replacing or cancelling
/// the ride notifies `cancelled`; a completed ride calls only `then`. A `paced` ride plays at most
/// MAX_FRAME_STEP_MS of its curve per painted frame, so it is seen as a ride however few frames the
/// page draws (a send's: reader input must always win, and a send is the reader's newest input).
export function animateScroll(
  node: HTMLElement,
  target: () => number,
  duration: number,
  curve: CubicBezier,
  then?: () => void,
  cancelled?: () => void,
  options: { explicit?: boolean; paced?: boolean } = {},
): void {
  const intent = userScrollIntent(node);
  if (intent.isHeld() && !options.explicit) return;
  stopScroll(node);
  let from = node.scrollTop;
  let last = from;
  runScroll(
    node,
    duration,
    curve,
    (progress) => {
      // Transcript placement can adjust the viewport while this motion is running (an older page
      // prepends above it). Rebase the origin by that external delta before writing the next
      // frame, so the jump follows the shared row-id anchor instead of restoring its stale
      // numeric starting offset.
      const externalDelta = node.scrollTop - last;
      if (Math.abs(externalDelta) > 0.5) from += externalDelta;
      const next = from + (target() - from) * progress;
      node.scrollTop = next;
      last = next;
    },
    then,
    cancelled,
    false,
    options.explicit,
    options.paced,
  );
  // After any `then`: the ride's landing is where the fling's momentum is held.
  if (running.has(node) || duration <= 0) holdMomentum(node, target);
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
  paced = false,
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
  // A paced ride's clock: the time it has played, at most MAX_FRAME_STEP_MS a frame.
  let played = 0;
  let last = start;
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
    if (paced) {
      played += Math.min(MAX_FRAME_STEP_MS, Math.max(0, now - last));
      last = Math.max(last, now);
    }
    const progress = Math.min(1, Math.max(0, (paced ? played : now - start) / duration));
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
