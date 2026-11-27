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
  pick?(row: HTMLElement, event: PointerEvent): void;
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
    if (!moved) moved = Math.hypot(event.clientX - start.clientX, event.clientY - start.clientY) >= SLOP;
    if (!moved) return;
    const row = rowAt(event);
    if (row) handlers.hover?.(row);
  };
  const up = (event: PointerEvent) => {
    const target = doc.elementFromPoint?.(event.clientX, event.clientY);
    const onTrigger = target != null && trigger.contains(target);
    const held = Date.now() - startedAt >= PRESS_CLICK_MS;
    const row = moved || held ? rowAt(event) : null;
    if (row) {
      (handlers.pick ?? clickRow)(row, event);
      handlers.picked?.(row);
    } else if (moved && held) {
      handlers.close?.();
    }
    handlers.end?.(onTrigger);
  };
  // Any other end (cancelled, or released where the page never heard it) picks and closes nothing.
  return watchPress(doc, {
    pointerId: start.pointerId,
    move,
    end: (how, event) => (how === "up" && event ? up(event) : handlers.end?.(false)),
  });
}

/**
 * Follows a press still held when a menu opened at the pointer (a right-click or Control-click: a
 * Mac sends `contextmenu` on the press) until its release: dragging onto a row of `menu` and
 * releasing clicks it; releasing after dragging away, held past a click, calls `close`. The same
 * rules as `trackPressRelease`, for a press with no trigger. Returns a cancel.
 */
export function trackHeldMenuRelease(
  doc: Document,
  start: { clientX: number; clientY: number },
  menu: () => HTMLElement | null,
  close: () => void,
): () => void {
  const startedAt = Date.now();
  let moved = false;
  const movedTo = (event: PointerEvent) => {
    if (!moved) moved = Math.hypot(event.clientX - start.clientX, event.clientY - start.clientY) >= SLOP;
  };
  const rowAt = (event: PointerEvent) => {
    const root = menu();
    const target = doc.elementFromPoint?.(event.clientX, event.clientY);
    if (!root || !target || !root.contains(target)) return null;
    const row = target.closest<HTMLElement>(PRESS_ROW);
    if (!row || row.matches('[aria-disabled="true"], :disabled')) return null;
    return row;
  };
  const move = (event: PointerEvent) => {
    if (event.pointerType !== "mouse") return;
    movedTo(event);
  };
  const up = (event: PointerEvent) => {
    if (event.pointerType !== "mouse") return;
    stop();
    movedTo(event);
    const held = Date.now() - startedAt >= PRESS_CLICK_MS;
    const row = moved || held ? rowAt(event) : null;
    if (row) row.click();
    else if (moved && held) close();
  };
  function stop() {
    doc.removeEventListener("pointermove", move, true);
    doc.removeEventListener("pointerup", up, true);
    doc.removeEventListener("pointercancel", stop, true);
  }
  doc.addEventListener("pointermove", move, true);
  doc.addEventListener("pointerup", up, true);
  doc.addEventListener("pointercancel", stop, true);
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

/**
 * How a press ended: its pointerup (mouseup), its pointercancel, its lost pointer capture, the
 * window's blur, or a move with no button down.
 */
export type PressEnd = "up" | "cancel" | "lostcapture" | "blur" | "released";

export interface PressWatch<E extends MouseEvent> {
  /** Only this pointer's events count; every pointer's when absent. */
  pointerId?: number;
  /** A move while the press lasts (a move with no button down ends it instead). */
  move?(event: E): void;
  /** The press ended, once; `event` is the event that ended it, none for the window's blur. */
  end(how: PressEnd, event?: E): void;
}

/**
 * Follows one press in `doc` until it ends, and returns a stop that removes every listener (call it
 * on unmount; it ends nothing). The page hears no pointerup for a press released where it cannot
 * see it: a mouse has no implicit pointer capture, so a button let go over another window, or after
 * the window lost focus mid-press, sends this page nothing. So besides the pointerup, the
 * pointercancel and the press losing its pointer capture, the window's own blur ends it (an
 * element's blur does not), and so does the first move with no button down (`buttons === 0`), the
 * first event the page hears once the pointer is back.
 *
 * `events: "mouse"` follows a press that starts on a mousedown with mousemove and mouseup.
 */
export function watchPress(doc: Document, watch: PressWatch<PointerEvent> & { events?: "pointer" }): () => void;
export function watchPress(doc: Document, watch: PressWatch<MouseEvent> & { events: "mouse" }): () => void;
export function watchPress(
  doc: Document,
  watch: (PressWatch<PointerEvent> | PressWatch<MouseEvent>) & { events?: "pointer" | "mouse" },
): () => void {
  const view = doc.defaultView;
  if (!view) return () => {};
  const mouse = watch.events === "mouse";
  const ours = (event: Event) =>
    watch.pointerId === undefined || mouse || (event as PointerEvent).pointerId === watch.pointerId;
  let done = false;
  const finish = (how: PressEnd, event?: MouseEvent) => {
    if (done) return;
    stop();
    (watch.end as (how: PressEnd, event?: MouseEvent) => void)(how, event);
  };
  const move = (event: Event) => {
    if (!ours(event)) return;
    const moved = event as MouseEvent;
    if (moved.buttons === 0) finish("released", moved);
    else (watch.move as ((event: MouseEvent) => void) | undefined)?.(moved);
  };
  const ends: [string, PressEnd][] = mouse
    ? [["mouseup", "up"]]
    : [
        ["pointerup", "up"],
        ["pointercancel", "cancel"],
        ["lostpointercapture", "lostcapture"],
      ];
  const handlers = ends.map(([type, how]) => {
    const handler = (event: Event) => {
      if (ours(event)) finish(how, event as MouseEvent);
    };
    return [type, handler] as const;
  });
  // Only the window's own blur: an element's reaches the window in the capture phase alone.
  const blur = (event: Event) => {
    if (event.target === view) finish("blur");
  };
  const moveType = mouse ? "mousemove" : "pointermove";
  function stop() {
    done = true;
    view!.removeEventListener(moveType, move, true);
    for (const [type, handler] of handlers) view!.removeEventListener(type, handler, true);
    view!.removeEventListener("blur", blur);
  }
  view.addEventListener(moveType, move, true);
  for (const [type, handler] of handlers) view.addEventListener(type, handler, true);
  view.addEventListener("blur", blur);
  return stop;
}
