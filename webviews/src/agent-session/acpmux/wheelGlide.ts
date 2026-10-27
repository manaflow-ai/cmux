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

/// Owns only notch input, on the existing single scroll clock. No anchor or follow-state writes.
/// A replacement jump, native wheel, other input, hidden page/pane, session switch or removal ends
/// the glide; the shared runner cancels its frame and listeners. The installer removes its wheel
/// listener on unmount. Completed notches leave no timer or listener behind.
export function installWheelGlide(node: HTMLElement): { stop(): void; remove(): void } {
  let ride: { remaining(): number } | undefined;
  const finished = () => {
    ride = undefined;
  };
  const stop = () => {
    if (ride) stopScroll(node);
    ride = undefined;
  };
  const onWheel = (event: WheelEvent) => {
    const root = node.ownerDocument.documentElement;
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
      root.dataset.wheelGlide === "off" ||
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
    ride = animateScrollBy(node, distance, duration, [0.22, 1, 0.36, 1], wanted >= max, finished);
  };
  node.addEventListener("wheel", onWheel, { passive: false });
  return {
    stop,
    remove: () => {
      stop();
      node.removeEventListener("wheel", onWheel);
    },
  };
}
