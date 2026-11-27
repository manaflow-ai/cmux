// A notched wheel eases its distance; precise trackpads and Mos stay native (Leo, 2026-10-22).
import { MOTION_MS } from "../../motion/scale.generated";
import { wheelTarget } from "../../scrollers";
import { isAgentMotionOff } from "../shared/motion";
import { animateScrollBy, reducedMotion, stopScroll } from "./threadMinimap/scrollMotion";
import { wheelPixels } from "./wheelPassThrough";

// WebKit's mouse-wheel lines use 16.16 fixed point and 40 px per line; precise input uses points.
// Ambiguous input stays native. Chromium distinguishes notches with legacy 120-unit wheel ticks.
export function isWheelNotch(event: Pick<WheelEvent, "deltaY" | "deltaMode"> & { wheelDeltaY?: number }): boolean {
  if (!event.deltaY) return false;
  if (event.deltaMode !== 0) return true;
  const legacy = event.wheelDeltaY;
  if (!legacy) return false;
  if (Math.abs(Math.abs(legacy) - 3 * Math.abs(event.deltaY)) < 1) {
    if (Number.isInteger(event.deltaY * 64)) return false;
    const fixed = (Math.abs(event.deltaY) / 40) * 65536;
    return Math.abs(fixed - Math.round(fixed)) < 1e-3;
  }
  return legacy % 120 === 0;
}

/// Sent (not bubbling) on the scroller when a notch's glide starts, from the wheel's own handler, and
/// when it ends: on its last step, or when anything cancels it (another input, a jump, a hidden page,
/// removal). A notch is the reader's own distance eased over a motion step: the reader's scroll is
/// under way until the end event, whatever `scrollend` events its writes fire meanwhile (Chromium
/// fires one after each). A notch that lands on a glide still easing continues it: no end between.
export const WHEEL_GLIDE_START_EVENT = "acpmux-wheel-glide-start";
export const WHEEL_GLIDE_END_EVENT = "acpmux-wheel-glide-end";

function announce(node: HTMLElement, type: string): void {
  // A stand-in scroller (a unit test's) may have no document or events of its own.
  if (typeof node.dispatchEvent !== "function") return;
  const Event_ = node.ownerDocument?.defaultView?.Event ?? globalThis.Event;
  if (Event_) node.dispatchEvent(new Event_(type));
}

/// Owns only notch input, on the existing single scroll clock. No anchor or follow-state writes.
/// A replacement jump, native wheel, other input, hidden page/pane, session switch or removal ends
/// the glide; the shared runner cancels its frame and listeners. The installer removes its wheel
/// listeners on unmount. Completed notches leave no timer or listener behind.
///
/// Only a notched wheel needs to cancel the browser's scroll, and a wheel listener that may cancel
/// makes WebKit send every wheel event to the page before it scrolls: a trackpad's scroll then
/// waited for whatever the page was doing (an older page of history landing), and stopped (Leo
/// 2026-10-29: "why is it sometimes blocking me from scrolling up further?"). So a passive listener
/// watches the wheel, and the cancelling one is there until the first precise (trackpad, Mos) event
/// and again from the next notch, which scrolls natively.
export function installWheelGlide(node: HTMLElement): { stop(): void; remove(): void } {
  let ride: { remaining(): number } | undefined;
  /// The glide that announced its start and has not announced its end.
  let gliding: object | undefined;
  const stop = () => {
    if (ride) stopScroll(node);
    ride = undefined;
  };
  const onWheel = (event: WheelEvent) => {
    if (
      event.defaultPrevented ||
      !event.cancelable ||
      event.ctrlKey ||
      event.metaKey ||
      event.shiftKey ||
      event.altKey ||
      Math.abs(event.deltaY) <= Math.abs(event.deltaX) ||
      !isWheelNotch(event) ||
      wheelTarget(event) !== node ||
      isAgentMotionOff() ||
      reducedMotion()
    ) {
      stop();
      return;
    }
    const token =
      node.ownerDocument.defaultView?.getComputedStyle(node).getPropertyValue("--agent-motion-move").trim() ?? "";
    const number = Number.parseFloat(token);
    const duration = Number.isFinite(number) ? number * (token.endsWith("ms") ? 1 : 1000) : MOTION_MS.standard;
    if (duration <= 0) {
      stop();
      return;
    }
    const max = Math.max(0, node.scrollHeight - node.clientHeight);
    const wanted = node.scrollTop + (ride?.remaining() ?? 0) + wheelPixels(event, node.clientHeight);
    const distance = Math.max(0, Math.min(max, wanted)) - node.scrollTop;
    // Equal reverse notches cancel the pending motion, rather than falling through to the browser.
    if (Math.abs(distance) < 0.5) {
      if (ride) {
        event.preventDefault();
        stop();
      }
      return;
    }
    event.preventDefault();
    // One glide from the first notch to the last: a notch that replaces the ride in flight ends that
    // ride (its `finished` runs inside animateScrollBy) without announcing an end in between.
    const continues = gliding !== undefined;
    const mine = {};
    gliding = mine;
    if (!continues) announce(node, WHEEL_GLIDE_START_EVENT);
    const finished = () => {
      if (gliding !== mine) return;
      gliding = undefined;
      ride = undefined;
      announce(node, WHEEL_GLIDE_END_EVENT);
    };
    ride = animateScrollBy(node, distance, duration, [0.22, 1, 0.36, 1], wanted >= max, finished);
    if (gliding !== mine) ride = undefined;
  };
  let armed = true;
  node.addEventListener("wheel", onWheel, { passive: false });
  const watch = (event: WheelEvent) => {
    if (!event.deltaY || Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return;
    const notch = isWheelNotch(event);
    if (notch === armed) return;
    armed = notch;
    if (notch) node.addEventListener("wheel", onWheel, { passive: false });
    else node.removeEventListener("wheel", onWheel);
  };
  node.addEventListener("wheel", watch, { passive: true });
  return {
    stop,
    remove: () => {
      stop();
      node.removeEventListener("wheel", watch);
      node.removeEventListener("wheel", onWheel);
      armed = false;
    },
  };
}
