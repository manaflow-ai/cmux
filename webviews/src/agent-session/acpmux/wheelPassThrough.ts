// The wheel over what floats on or under the transcript scrolls the transcript (Leo 2026-10-19:
// "can't scroll when cursor on the jump to bottom", "can't scroll from bottom composer area"), as
// it does in the Claude and Codex apps. The Jump to latest button and the bottom stack (questions,
// notices, the queue, the composer) are not inside the transcript's scroller, so a wheel or
// trackpad scroll over them reached nothing. A part that scrolls itself (a long prompt, the queue,
// a menu's list) keeps the wheel while it can still move that way.

/// Parts of the pane over which the wheel scrolls the transcript: Jump to latest, and every part
/// of `main` outside the stage (the stage holds the header and the transcript itself).
export function passesWheelToTranscript(target: Element, main: Element): boolean {
  if (target.closest(".acpmux-jump-latest")) return true;
  if (target.closest('[role="menu"], [role="listbox"], [role="dialog"]')) return false;
  let part: Element | null = target;
  while (part && part.parentElement !== main) part = part.parentElement;
  if (!part) return false;
  return !part.classList.contains("acpmux-stage") && !part.classList.contains("acpmux-home-area");
}

/// Whether something between `target` and `stop` scrolls itself by `deltaY` (it is scrollable and
/// not at its end that way), so the wheel is its own.
export function scrollsItself(target: Element, stop: Element, deltaY: number): boolean {
  for (let box: Element | null = target; box && box !== stop; box = box.parentElement) {
    if (box.scrollHeight <= box.clientHeight + 1) continue;
    const style = getComputedStyle(box);
    if (!/auto|scroll/.test(style.overflowY)) continue;
    if (deltaY < 0 && box.scrollTop > 0) return true;
    if (deltaY > 0 && box.scrollTop + box.clientHeight < box.scrollHeight - 1) return true;
  }
  return false;
}

/// The event's vertical distance in pixels (a line is 16px, a page the scroller's height).
export function wheelPixels(event: Pick<WheelEvent, "deltaY" | "deltaMode">, pageHeight: number): number {
  if (event.deltaMode === 1) return event.deltaY * 16;
  if (event.deltaMode === 2) return event.deltaY * pageHeight;
  return event.deltaY;
}

/// Sends the wheel over `main`'s floating parts to `scroller`. The scroller first gets a copy of
/// the event, so its own wheel listeners run as for a wheel over it (the scroll counts as the
/// reader's, a glide or a Jump to latest in flight ends). The listener is passive: a wheel over the
/// transcript itself never waits on it, and a part that cannot scroll has no native scroll to stop.
/// Returns the remover.
export function installWheelPassThrough(scroller: HTMLElement, main: HTMLElement): () => void {
  const onWheel = (event: WheelEvent) => {
    if (event.defaultPrevented || event.ctrlKey) return;
    if (Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return;
    const target = event.target instanceof Element ? event.target : null;
    if (!target || scroller.contains(target) || !passesWheelToTranscript(target, main)) return;
    if (scrollsItself(target, main, event.deltaY)) return;
    scroller.dispatchEvent(
      new WheelEvent("wheel", { deltaX: 0, deltaY: event.deltaY, deltaMode: event.deltaMode, bubbles: false }),
    );
    scroller.scrollTop += wheelPixels(event, scroller.clientHeight);
  };
  main.addEventListener("wheel", onWheel, { passive: true });
  return () => main.removeEventListener("wheel", onWheel);
}
