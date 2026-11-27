// The edited-files card's file stack scrolls where the reader is looking (Lucas, 2026-11-25: "it should be
// almost spatially aware of where I'm scrolling"). A wheel over the stack first moves the transcript until
// the card is in full view above the bottom stack (the composer), then scrolls the stack, and once the stack
// has reached its end hands what is left of the wheel back to the transcript, in one gesture. macOS latches
// a gesture to the box it started in, so native scroll chaining alone held the reader in the stack, and a
// card half under the composer scrolled its lines out of sight.
import { forwardWheel, wheelPixels } from "../wheelPassThrough";
import { isWheelNotch } from "../wheelGlide";

/// The room kept between the card and the view's edge when the transcript brings it into view.
const EDGE = 8;

type Span = { top: number; bottom: number };

/// How a vertical wheel of `delta` px splits: `bring` scrolls the transcript first, to bring `card` into
/// `view` (never past the card's other edge, so a card taller than the view is not pushed out of it), `stack`
/// scrolls the file stack with `room` px left that way, and `after` goes on to the transcript past the
/// stack's end. Signed as `delta`; the three add up to it.
export function splitWheel(
  delta: number,
  card: Span,
  view: Span,
  room: number,
): { bring: number; stack: number; after: number } {
  const down = delta > 0;
  const want = down
    ? Math.min(card.bottom - (view.bottom - EDGE), card.top - (view.top + EDGE))
    : Math.min(view.top + EDGE - card.top, view.bottom - EDGE - card.bottom);
  // `+ 0` makes a share of none 0, never -0.
  const bring = Math.max(0, Math.min(Math.abs(delta), want)) * Math.sign(delta) + 0;
  const rest = delta - bring;
  const stack = Math.min(Math.abs(rest), Math.max(0, room)) * Math.sign(delta) + 0;
  return { bring, stack, after: rest - stack + 0 };
}

/// The transcript the stack lies in: its nearest ancestor that scrolls vertically.
function transcriptOf(stack: HTMLElement): HTMLElement | null {
  for (let at = stack.parentElement; at; at = at.parentElement) {
    if (at.scrollHeight <= at.clientHeight) continue;
    const overflow = getComputedStyle(at).overflowY;
    if (overflow === "auto" || overflow === "scroll") return at;
  }
  return null;
}

/// A wheel of `deltaY` px for the transcript, else a copy of `event` (a notch keeps its own delta and
/// legacy ticks, so the transcript's glide still eases it).
function wheelFor(event: WheelEvent, deltaY?: number): WheelEvent {
  const copy = new WheelEvent("wheel", {
    deltaX: 0,
    deltaY: deltaY ?? event.deltaY,
    deltaMode: deltaY === undefined ? event.deltaMode : 0,
    cancelable: true,
  });
  if (deltaY === undefined)
    Object.defineProperty(copy, "wheelDeltaY", {
      value: (event as WheelEvent & { wheelDeltaY?: number }).wheelDeltaY,
    });
  return copy;
}

/// Scrolls `stack` and its transcript by `splitWheel`. A wheel the stack takes whole stays native, so its
/// scrolling stays the engine's own; any other is taken here and sent to the transcript through
/// `forwardWheel`, as a wheel over it, so the reader's scroll, the glide and the bottom stack's room all
/// see it. A pinch or a mostly sideways wheel (a code row's) is left alone. Returns the remover.
export function installStackWheel(stack: HTMLElement): () => void {
  const onWheel = (event: WheelEvent) => {
    if (event.defaultPrevented || event.ctrlKey || event.metaKey) return;
    if (Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return;
    const transcript = transcriptOf(stack);
    if (!transcript) return;
    const delta = wheelPixels(event, stack.clientHeight);
    const room = delta > 0 ? stack.scrollHeight - stack.clientHeight - stack.scrollTop : stack.scrollTop;
    const card = (stack.closest(".acpmux-edited") ?? stack).getBoundingClientRect();
    const box = transcript.getBoundingClientRect();
    const dock = Number.parseFloat(transcript.style.getPropertyValue("--acpmux-dock-space")) || 0;
    const view = { top: box.top, bottom: Math.max(box.top, box.bottom - dock) };
    const { bring, stack: own, after } = splitWheel(delta, card, view, room);
    if (!bring && !after) return;
    event.preventDefault();
    // Its listeners on the way up would see the wheel twice: the transcript gets its own copy below.
    event.stopPropagation();
    if (isWheelNotch(event)) {
      // A notch moves one thing, eased by the transcript's glide: the card into view, else the stack, else on.
      if (bring || !own) forwardWheel(transcript, wheelFor(event));
      else stack.scrollTop += own;
      return;
    }
    if (bring) forwardWheel(transcript, wheelFor(event, bring));
    if (own) stack.scrollTop += own;
    if (after) forwardWheel(transcript, wheelFor(event, after));
  };
  stack.addEventListener("wheel", onWheel, { passive: false });
  return () => stack.removeEventListener("wheel", onWheel);
}
