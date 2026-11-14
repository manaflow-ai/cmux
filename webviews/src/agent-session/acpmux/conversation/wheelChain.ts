// Which scroller a wheel down moves, for the transcript's follow rule (VirtualTranscript.tsx
// `readerDown`): only the reader's own downward scroll of the transcript brings following back
// (Leo, 2026-11-07: "Like I can just click the jump to bottom button if I want").

const SCROLLABLE = new Set(["auto", "scroll", "overlay"]);

/// Whether a wheel down over `event`'s target scrolls `scroller` itself. The browser hands the wheel
/// to the innermost element on its path that can still scroll down; one at its bottom passes it on
/// to the next, unless its `overscroll-behavior` (contain or none) keeps the wheel. A tool's output
/// at its end therefore moves the transcript, and one with room left moves only itself. O(depth of
/// the path), a few style reads per wheel event.
export function wheelScrollsDown(event: Pick<WheelEvent, "composedPath" | "deltaY">, scroller: Element): boolean {
  if (event.deltaY <= 0) return false;
  for (const node of event.composedPath()) {
    if (node === scroller) return true;
    const element = node as Element;
    if (typeof element.getAttribute !== "function" || typeof element.scrollHeight !== "number") continue;
    if (element.scrollHeight <= element.clientHeight + 0.5) continue;
    const style = element.ownerDocument.defaultView?.getComputedStyle(element);
    if (!style || !SCROLLABLE.has(style.overflowY)) continue;
    // Room left below: the wheel scrolls this element, not the transcript.
    if (element.scrollTop + element.clientHeight < element.scrollHeight - 1) return false;
    // At its bottom, it passes the wheel on unless it contains its overscroll.
    if (style.overscrollBehaviorY === "contain" || style.overscrollBehaviorY === "none") return false;
  }
  return false;
}

/// A text field (input, textarea, select, contenteditable): its keys move its own caret.
export function editableTarget(target: EventTarget | null): boolean {
  const element = target as Element | null;
  return (
    typeof element?.closest === "function" &&
    element.closest("input, textarea, select, [contenteditable]:not([contenteditable=false])") !== null
  );
}
