// The wheel over Jump to latest scrolls the transcript (Leo 2026-10-19: "can't scroll when cursor on
// the jump to bottom"), as it does in the Claude and Codex apps: the button floats over the
// transcript's foot but is not inside its scroller, so a wheel over it reached nothing. The bottom
// stack (questions, notices, the queue, the composer and its footer) is a no-scroll zone (Leo
// 2026-10-20: "all of these areas are essentially a no-scroll zone"): the wheel over its parts
// scrolls neither the transcript nor the stack, and a part that scrolls itself (a long prompt, the
// queue, a menu's list) keeps the wheel at its ends too. The gutters beside and under the composer's
// card are not part of it: the dock passes them through, so the wheel there scrolls the transcript
// (Leo 2026-10-20: "if it's not in the composer it should just scroll"; bottomStack.css).

/// The event's vertical distance in pixels (a line is 16px, a page the scroller's height).
export function wheelPixels(event: Pick<WheelEvent, "deltaY" | "deltaMode">, pageHeight: number): number {
  if (event.deltaMode === 1) return event.deltaY * 16;
  if (event.deltaMode === 2) return event.deltaY * pageHeight;
  return event.deltaY;
}

/// Sends the wheel over Jump to latest in `main` to `scroller`. The scroller first gets a copy of the
/// event, so its own wheel listeners run as for a wheel over it (the scroll counts as the reader's, a
/// glide or a Jump to latest in flight ends). The listener is passive: a wheel over the transcript
/// itself never waits on it. Returns the remover.
export function installWheelPassThrough(scroller: HTMLElement, main: HTMLElement): () => void {
  const onWheel = (event: WheelEvent) => {
    if (event.defaultPrevented || event.ctrlKey) return;
    if (Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return;
    const target = event.target instanceof Element ? event.target : null;
    if (!target?.closest(".acpmux-jump-latest") || scroller.contains(target)) return;
    scroller.dispatchEvent(
      new WheelEvent("wheel", { deltaX: 0, deltaY: event.deltaY, deltaMode: event.deltaMode, bubbles: false }),
    );
    scroller.scrollTop += wheelPixels(event, scroller.clientHeight);
  };
  main.addEventListener("wheel", onWheel, { passive: true });
  return () => main.removeEventListener("wheel", onWheel);
}
