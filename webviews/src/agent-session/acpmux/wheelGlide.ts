// A mouse wheel glides the transcript (Leo 2026-10-22: "smoother scrolling in webkit: i mean with a
// mouse instead of just trackpad. i have mos and lawrence doesn't, tho we'd presumably be doing a
// bit of our handrolled mos-ish thing"). WebKit applies a mouse wheel's step in one frame, so a
// spun wheel moves the transcript in jumps; a trackpad's (and Mos's) many small steps already read
// as smooth. Each notch here eases the view toward where the wheel has sent it instead, and a notch
// during a glide adds to where it is headed. Trackpad and momentum scrolling are never touched.
import { MOTION_MS } from "../../motion/scale.generated";
import { isAgentMotionOff } from "../shared/motion";
import { wheelTarget } from "../../scrollers";
import { reducedMotion } from "./threadMinimap/scrollMotion";
import { wheelPixels } from "./wheelPassThrough";

/// How long one notch's glide runs, eased out (a notch during it starts a new one from where it is):
/// the motion scale's step for a structural move.
export const WHEEL_GLIDE_MS = MOTION_MS.standard;

/// One display frame at 60Hz.
const FRAME_MS = 1000 / 60;
/// Pixels per wheel line: the line WebKit and Chromium scroll per notch tick on macOS.
const LINE_PX = 40;
/// macOS keeps a wheel's accelerated lines in 16.16 fixed point.
const FIXED_POINT = 65536;

/// Inputs that end a glide where it is: the reader takes the view (a press on the scrollbar, a row,
/// Jump to latest or the minimap; a touch; a key).
const READER_INPUTS = ["pointerdown", "touchstart", "keydown"] as const;

/// Debug Settings' `agentPane.debug.wheelGlide` (on by default): off, the app sets
/// `data-wheel-glide="off"` on <html> and the wheel scrolls as the engine does.
export const wheelGlideOn = () =>
  typeof document === "undefined" || document.documentElement.dataset.wheelGlide !== "off";

/// Whether `event` is a mouse wheel's notch rather than a trackpad's (or Magic Mouse's, or Mos's)
/// precise scroll. No engine says which device sent a wheel event, but each leaves a mark:
/// - Lines or pages (Firefox, and Chromium's line-scroll setting) come from a wheel.
/// - Chromium counts a notch as 120 in the legacy `wheelDeltaY`, whatever pixels it scrolls (4px
///   for a slow notch on macOS, 100 on Windows); a precise device's is three times its pixels.
/// - WebKit gives every wheel event a `wheelDeltaY` of three times its pixels (its ticks are pixels
///   over 40, times 120), so the pixels decide: a notch on macOS scrolls its accelerated lines times
///   40, and those lines are 16.16 fixed point (a slow notch is 0.1 lines, 4.000244140625px), while
///   a trackpad scrolls whole points. Any multiple of 1/64px counts as a trackpad's too, in case one
///   reports fractions of a point: a notch's lines land on one only once in 512.
/// A notch this cannot tell from a trackpad (a whole number of pixels with a precise-looking
/// `wheelDeltaY`) scrolls as the engine does: never the other way round.
export function isWheelNotch(event: Pick<WheelEvent, "deltaY" | "deltaMode"> & { wheelDeltaY?: number }): boolean {
  if (event.deltaY === 0) return false;
  if (event.deltaMode !== 0) return true;
  const legacy = event.wheelDeltaY;
  if (typeof legacy !== "number" || legacy === 0) return false;
  // The legacy value is a whole number, cut from three times a fractional pixel count.
  if (Math.abs(Math.abs(legacy) - 3 * Math.abs(event.deltaY)) < 1) {
    if (Number.isInteger(event.deltaY * 64)) return false;
    const fixed = (Math.abs(event.deltaY) / LINE_PX) * FIXED_POINT;
    return Math.abs(fixed - Math.round(fixed)) < 1e-3;
  }
  return legacy % 120 === 0;
}

const ease = (t: number) => 1 - (1 - t) ** 3;

/// Glides `scroller` for each mouse wheel notch over it (`isWheelNotch`): the notch's distance is
/// added to where the view is headed, and the view eases there over WHEEL_GLIDE_MS. The glide moves
/// the view by its own steps, so rows that land above meanwhile (older history, a row that measured)
/// keep the reader's place as they do for any scroll. A wheel event the engine scrolls itself (a
/// trackpad's, one over a row that scrolls on its own, one with the view already at that end) and
/// Reduce Motion or the Debug toggle off leave the event to the engine.
///
/// Stop conditions: the glide's frame loop ends when it has covered its distance or reached an end,
/// at a trackpad's (or modified, sideways or nested scroller's) wheel event, at the reader's press,
/// touch or key anywhere in the page, when the scroller or the page is hidden, and on `stop()` (Jump
/// to latest, a switch to another chat). Cleanup: the returned remover ends a glide in flight and
/// removes the wheel and scroll listeners (the page's input and visibility listeners live only while
/// a glide runs).
export function installWheelGlide(scroller: HTMLElement): { stop: () => void; remove: () => void } {
  const doc = scroller.ownerDocument;
  const page = doc.defaultView ?? window;
  let frame = 0;
  /// Distance this glide covers from its start, how much of it is done, and when it started.
  let distance = 0;
  let done = 0;
  let start = 0;
  /// Where the glide puts the view, in fractional pixels (the engine may keep whole ones), and the
  /// offset it read back after its last step: a different one means rows moved the view meanwhile.
  let position = 0;
  let wrote = 0;
  /// The offset a step announced with its own scroll event, until the browser's event for that write.
  let announced: number | undefined;
  /// Whether the wheel sent the view to the bottom: a reply that grows meanwhile moves the bottom, and
  /// the glide follows it there, so it lands where the chat follows the reply.
  let toEnd = false;
  const stop = () => {
    if (!frame) return;
    cancelAnimationFrame(frame);
    frame = 0;
    distance = 0;
    done = 0;
    toEnd = false;
    for (const name of READER_INPUTS) page.removeEventListener(name, stop, true);
    doc.removeEventListener("visibilitychange", onVisibility);
  };
  /// A page hidden mid-glide (another tab, a hidden workspace, the app in the background): WebKit
  /// holds a hidden page's frames, and the first one back would finish the glide in one jump.
  const onVisibility = () => {
    if (doc.hidden) stop();
  };
  const step = (now: number) => {
    // A pane hidden mid-glide has no height: the glide ends where it is.
    if (scroller.clientHeight === 0 || doc.hidden) {
      stop();
      return;
    }
    if (start < 0) start = now - FRAME_MS;
    const progress = Math.min(1, Math.max(0, (now - start) / WHEEL_GLIDE_MS));
    // Rows that landed or measured moved the view: the glide carries on from where they put it.
    position += scroller.scrollTop - wrote;
    const max = scroller.scrollHeight - scroller.clientHeight;
    // Headed for the bottom, and the reply below grew: the rest of the glide goes to the new bottom.
    if (toEnd) {
      const short = max - (position + distance - done);
      if (short > 0) distance += short;
    }
    const next = distance * ease(progress);
    position += next - done;
    done = next;
    const before = scroller.scrollTop;
    scroller.scrollTop = position;
    wrote = scroller.scrollTop;
    // A write in a frame callback raises its scroll event only in the next frame, so everything that
    // follows the offset (the rows mounted around it, the minimap's lit band) would paint a frame
    // behind. The step announces it now, as a wheel's own scroll does, and the browser's event for
    // the same offset is dropped when it comes (onBrowserScroll).
    if (Math.abs(wrote - before) >= 0.5) {
      announced = wrote;
      scroller.dispatchEvent(new Event("scroll"));
    }
    // At an end the rest of the distance goes nowhere.
    const blocked = (distance < 0 && wrote <= 0) || (distance > 0 && wrote >= max - 0.5);
    if (progress >= 1 || blocked) stop();
    else frame = requestAnimationFrame(step);
  };
  const onWheel = (event: WheelEvent) => {
    // A pinch, a modified or sideways wheel, or one a listener already took is not a notch to glide;
    // any of them ends a glide in flight where it is.
    if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) {
      stop();
      return;
    }
    // A diagonal one, as much sideways as down, is the engine's too (wheelPassThrough's rule).
    if (Math.abs(event.deltaY) <= Math.abs(event.deltaX)) {
      stop();
      return;
    }
    if (!isWheelNotch(event as WheelEvent & { wheelDeltaY?: number })) {
      // A trackpad (or momentum) scroll takes over from a glide where it is.
      stop();
      return;
    }
    if (!event.cancelable || !wheelGlideOn() || isAgentMotionOff() || reducedMotion()) {
      stop();
      return;
    }
    // A row that scrolls on its own (a long tool output, a code view) takes the wheel first, as it
    // does today, and a glide in flight ends where it is: the wheel belongs to that row now.
    if (wheelTarget(event) !== scroller) {
      stop();
      return;
    }
    const max = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
    const gliding = frame !== 0;
    const from = gliding ? position + scroller.scrollTop - wrote : scroller.scrollTop;
    const headed = gliding ? from + distance - done : from;
    const wanted = headed + wheelPixels(event, scroller.clientHeight);
    const target = Math.max(0, Math.min(max, wanted));
    // Already at that end: nothing to glide (and the event still asks for older history at the top).
    if (Math.abs(target - from) < 0.5) return;
    event.preventDefault();
    position = from;
    wrote = scroller.scrollTop;
    distance = target - from;
    done = 0;
    toEnd = wanted >= max - 0.5;
    // The glide starts in the next frame, one frame along, so a notch never waits a frame unmoved.
    start = -1;
    if (!gliding) {
      // Captured on the window: the press on Jump to latest or the minimap lands outside the scroller.
      for (const name of READER_INPUTS) page.addEventListener(name, stop, { capture: true, passive: true });
      doc.addEventListener("visibilitychange", onVisibility);
      frame = requestAnimationFrame(step);
    }
  };
  /// The browser's scroll event for a step's write: its listeners heard that offset already. Captured
  /// on the scroller, so it comes before the listeners added there without capture.
  const onBrowserScroll = (event: Event) => {
    if (announced === undefined || !event.isTrusted) return;
    const same = Math.abs(scroller.scrollTop - announced) < 0.5;
    announced = undefined;
    if (same) event.stopImmediatePropagation();
  };
  scroller.addEventListener("wheel", onWheel, { passive: false });
  scroller.addEventListener("scroll", onBrowserScroll, { capture: true, passive: true });
  return {
    stop,
    remove: () => {
      stop();
      announced = undefined;
      scroller.removeEventListener("wheel", onWheel);
      scroller.removeEventListener("scroll", onBrowserScroll, { capture: true });
    },
  };
}
