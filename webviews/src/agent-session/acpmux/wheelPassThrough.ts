// The wheel over Jump to latest scrolls the transcript (Leo 2026-10-19: "can't scroll when cursor on
// the jump to bottom"), as it does in the Claude and Codex apps: the button floats over the
// transcript's foot but is not inside its scroller, so a wheel over it reached nothing. The bottom
// stack (questions, notices, the queue, the composer and its footer) is a no-scroll zone (Leo
// 2026-10-20: "all of these areas are essentially a no-scroll zone"): the wheel over its parts
// scrolls neither the transcript nor the stack, and a part that scrolls itself (a long prompt, the
// queue, a menu's list) keeps the wheel at its ends too. The gutters and empty room beside each part's
// card are not part of it (Leo 2026-10-20: "if it's not in the composer it should just scroll"): the
// composer passes the pointer through beside its card (bottomStack.css), and the other parts' bands,
// which take the pointer so nothing reaches the masked rows under them, send the wheel on here.

/// The event's vertical distance in pixels (a line is 16px, a page the scroller's height).
export function wheelPixels(event: Pick<WheelEvent, "deltaY" | "deltaMode">, pageHeight: number): number {
  if (event.deltaMode === 1) return event.deltaY * 16;
  if (event.deltaMode === 2) return event.deltaY * pageHeight;
  return event.deltaY;
}

/// Whether the wheel over `target` goes to the transcript: over Jump to latest, or over a part of the
/// floating stack itself (its gutters and empty room, not what it holds), unless that part scrolls.
/// The composer passes the pointer through instead, and the dictation notice is a card of its own.
function passesThrough(target: Element): boolean {
  if (target.closest(".acpmux-jump-latest")) return true;
  if (!target.parentElement?.matches(".acpmux-main[data-dock=float] > .acpmux-dock")) return false;
  if (target.matches(".acpmux-composer, .acpmux-dictation-notice")) return false;
  return target.scrollHeight <= target.clientHeight;
}

/// Scrolls `scroller` by a vertical wheel that landed outside it. The scroller first gets a copy of
/// the event, so its own wheel listeners run as for a wheel over it (the scroll counts as the
/// reader's, a glide, a minimap jump or a Jump to latest in flight ends). A pinch (ctrl) or a mostly
/// sideways wheel is left alone.
export function forwardWheel(scroller: HTMLElement, event: WheelEvent): void {
  if (event.defaultPrevented || event.ctrlKey) return;
  if (Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return;
  const copy = new WheelEvent("wheel", {
    deltaX: event.deltaX,
    deltaY: event.deltaY,
    deltaMode: event.deltaMode,
    ctrlKey: event.ctrlKey,
    metaKey: event.metaKey,
    shiftKey: event.shiftKey,
    altKey: event.altKey,
    cancelable: true,
  });
  Object.defineProperty(copy, "wheelDeltaY", { value: (event as WheelEvent & { wheelDeltaY?: number }).wheelDeltaY });
  scroller.dispatchEvent(copy);
  if (!copy.defaultPrevented) scroller.scrollTop += wheelPixels(event, scroller.clientHeight);
}

/// Sends the wheel over Jump to latest, or over a floating stack part's empty room, in `main` to
/// `scroller` (forwardWheel). The listener is passive: a wheel over the transcript itself never
/// waits on it. Returns the remover.
export function installWheelPassThrough(scroller: HTMLElement, main: HTMLElement): () => void {
  const onWheel = (event: WheelEvent) => {
    const target = event.target instanceof Element ? event.target : null;
    if (!target || !passesThrough(target) || scroller.contains(target)) return;
    forwardWheel(scroller, event);
  };
  main.addEventListener("wheel", onWheel, { passive: true });
  return () => main.removeEventListener("wheel", onWheel);
}
