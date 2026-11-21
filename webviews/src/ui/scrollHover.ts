// Hover cards and scrolling (Leo, 2026-11-10: "just tried this touchpad scrolling the github preview
// is kinda bad"). While he scrolled the transcript with the touchpad and the pointer still, a pull
// request's card kept opening for whichever chip slid under the pointer, and an open card rode along
// with its link. Two rules, for every hover card:
//
// - A wheel or touchpad scroll (any momentum) puts an open card away at once, as a macOS hover card
//   or popover goes when its content scrolls; a scroll inside the card itself keeps it.
// - Content moving under a pointer that did not move is no hover: the browser sends pointerover and
//   pointerenter when a link scrolls (or is laid out) under a still pointer, at the point of the last
//   real pointermove. Such an enter waits until the pointer itself moves on its target.
//
// One document listener pair serves every card on the page.

export type PointerPlace = { x: number; y: number };

let last: PointerPlace | undefined;
let installedOn: Document | undefined;
const wheelListeners = new Set<(target: EventTarget | null) => void>();

function install(doc: Document) {
  if (installedOn === doc) return;
  installedOn = doc;
  last = undefined;
  // Capture, so the place is current before any element's own handler reads it.
  doc.addEventListener(
    "pointermove",
    (event) => {
      if (event.pointerType === "touch") return;
      last = { x: event.clientX, y: event.clientY };
    },
    true,
  );
  doc.addEventListener(
    "wheel",
    (event) => {
      // A copy: a card's listener may unsubscribe (unmount) while the wheel is handled.
      for (const listener of Array.from(wheelListeners)) listener(event.target);
    },
    { capture: true, passive: true },
  );
}

/** Starts tracking the pointer on `doc` (once per document); a hover card's hook calls it on mount. */
export function trackPointerRest(doc: Document | undefined = typeof document === "undefined" ? undefined : document) {
  if (doc) install(doc);
}

/**
 * Whether a pointerenter or pointerover at `event` came from content moving under a still pointer:
 * it lands exactly where the last real pointermove was. A real move into a target sends its enter
 * before its move, so a real enter is at a new place.
 */
export function slidUnderStillPointer(event: { clientX: number; clientY: number; pointerType?: string }): boolean {
  if (event.pointerType === "touch" || !last) return false;
  return event.clientX === last.x && event.clientY === last.y;
}

/** The pointer's place now (the last real pointermove), for a parked hover to compare against. */
export function pointerPlace(): PointerPlace | undefined {
  return last;
}

/** Whether a pointer event is at a place other than `from`: the pointer itself moved. */
export function movedFrom(from: PointerPlace | undefined, event: { clientX: number; clientY: number }): boolean {
  return !from || event.clientX !== from.x || event.clientY !== from.y;
}

/** Calls `listener` with the target of every wheel event on the page (a touchpad's momentum too). */
export function onWheel(listener: (target: EventTarget | null) => void): () => void {
  trackPointerRest();
  wheelListeners.add(listener);
  return () => wheelListeners.delete(listener);
}

/** @internal Tests: forget the pointer and the document. */
export function resetPointerRestForTests() {
  last = undefined;
  installedOn = undefined;
  wheelListeners.clear();
}
