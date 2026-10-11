// Press-drag-release, the macOS menu gesture, for every menu and popover trigger: a press on the
// trigger opens the menu, dragging onto a row and releasing picks it. A release on the trigger
// soon after the press, or without moving, is a plain click and leaves the menu open; a release
// after dragging away (back on the trigger or anywhere but a row) closes it.

/** A release this soon after the press is a click, never a pick or a close. */
export const PRESS_CLICK_MS = 150;
const SLOP = 4;
/** What a release can pick: listbox options, menu items, and rows that opt in. */
export const PRESS_ROW = '[role="option"], [role^="menuitem"], [data-press-pick]';

export interface PressReleaseHandlers {
  /** The row under the pointer while the press drags. */
  hover?(row: HTMLElement): void;
  /** Picks `row` (default: a mouse press and click on it, as rows pick on either). */
  pick?(row: HTMLElement): void;
  /** Released on `row`, after it was picked. */
  picked?(row: HTMLElement): void;
  /** Released after dragging away, not on a row. */
  close?(): void;
  /** The press ended; `onTrigger` when released on the trigger (its click follows). */
  end?(onTrigger: boolean): void;
}

interface PressStart {
  pointerId: number;
  clientX: number;
  clientY: number;
  currentTarget: EventTarget | null;
}

/** Follows the mouse press `start` on its trigger until the release. Returns a cancel. */
export function trackPressRelease(start: PressStart, handlers: PressReleaseHandlers = {}): () => void {
  const trigger = start.currentTarget as HTMLElement;
  const doc = trigger.ownerDocument;
  const startedAt = Date.now();
  let moved = false;
  const rowAt = (event: PointerEvent) => {
    const target = doc.elementFromPoint?.(event.clientX, event.clientY);
    // Any element: a row's icon (an SVG) picks its row too.
    if (!target || trigger.contains(target)) return null;
    const row = target.closest<HTMLElement>(PRESS_ROW);
    if (!row || row.matches('[aria-disabled="true"], :disabled')) return null;
    return row;
  };
  const move = (event: PointerEvent) => {
    if (event.pointerId !== start.pointerId) return;
    if (!moved) moved = Math.hypot(event.clientX - start.clientX, event.clientY - start.clientY) >= SLOP;
    if (!moved) return;
    const row = rowAt(event);
    if (row) handlers.hover?.(row);
  };
  const up = (event: PointerEvent) => {
    if (event.pointerId !== start.pointerId) return;
    stop();
    const target = doc.elementFromPoint?.(event.clientX, event.clientY);
    const onTrigger = target != null && trigger.contains(target);
    const held = Date.now() - startedAt >= PRESS_CLICK_MS;
    const row = moved || held ? rowAt(event) : null;
    if (row) {
      (handlers.pick ?? clickRow)(row);
      handlers.picked?.(row);
    } else if (moved && held) {
      handlers.close?.();
    }
    handlers.end?.(onTrigger);
  };
  const cancel = (event: PointerEvent) => {
    if (event.pointerId !== start.pointerId) return;
    stop();
    handlers.end?.(false);
  };
  function stop() {
    doc.removeEventListener("pointermove", move, true);
    doc.removeEventListener("pointerup", up, true);
    doc.removeEventListener("pointercancel", cancel, true);
  }
  doc.addEventListener("pointermove", move, true);
  doc.addEventListener("pointerup", up, true);
  doc.addEventListener("pointercancel", cancel, true);
  return stop;
}

/** A click on `row` as the mouse makes it: rows pick on the press or on the click. */
function clickRow(row: HTMLElement) {
  const View = row.ownerDocument.defaultView?.MouseEvent ?? MouseEvent;
  row.dispatchEvent(new View("mousedown", { bubbles: true, cancelable: true, button: 0 }));
  // A row that picked on the press may be gone with its popover.
  if (row.isConnected) row.click();
}

/** A primary mouse press: the only press that drags to pick (touch and pen tap). */
export function isMousePress(event: { pointerType: string; button: number }): boolean {
  return event.pointerType === "mouse" && event.button === 0;
}
