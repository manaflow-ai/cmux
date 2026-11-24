// A drag on a popup's edge or corner sets its size; the edges nearest its anchor stay put. The model
// menu (QuickModelColumns.tsx) and every composer dropdown (PopupResize.tsx) share this drag and the
// size store, so they all resize the same way (cmux#51745): a menu that opens up grows from its top
// edge, the side edge away from the chip, and the corner between them; one that opens down grows
// from its bottom edge, the same side edge, and that corner.

/// One size the person dragged a popup to, in px, kept in local storage under `key`. The sizes kept
/// under `retired` keys (an older default's) are dropped once, so an update that changes the default
/// starts everyone from it; a drag after that is kept as before (Lucas 2026-11-12). Every open page
/// (another chat's tab, the New Tab page) follows a change through the storage event.
export function sizeStore(key: string, least: number, retired: readonly string[] = []) {
  try {
    for (const old of retired) globalThis.localStorage?.removeItem(old);
  } catch {
    // A blocked store has nothing to drop.
  }
  const stored = (): number | undefined => {
    try {
      const value = Number(globalThis.localStorage?.getItem(key));
      return Number.isFinite(value) && value >= least ? Math.round(value) : undefined;
    } catch {
      return undefined;
    }
  };
  let size = stored();
  const listeners = new Set<() => void>();
  const get = (): number | undefined => size;
  const set = (next: number | undefined) => {
    const value = next === undefined ? undefined : Math.max(least, Math.round(next));
    if (value === size) return;
    size = value;
    try {
      if (value === undefined) globalThis.localStorage?.removeItem(key);
      else globalThis.localStorage?.setItem(key, String(value));
    } catch {
      // A blocked store keeps the size for this page only.
    }
    for (const listener of listeners) listener();
  };
  const subscribe = (listener: () => void) => {
    listeners.add(listener);
    // Another page (another chat's tab, the New Tab page) changed it.
    const changed = (event: StorageEvent) => {
      if (event.key !== key && event.key !== null) return;
      const next = stored();
      if (next === size) return;
      size = next;
      for (const each of listeners) each();
    };
    globalThis.addEventListener?.("storage", changed);
    return () => {
      listeners.delete(listener);
      globalThis.removeEventListener?.("storage", changed);
    };
  };
  return { get, set, subscribe };
}

export type SizeStore = ReturnType<typeof sizeStore>;

/** Which dimensions a grip changes: its side edge's, its top or bottom edge's, or the corner's both. */
export type PopupResizeAxes = "width" | "height" | "both";

/** The box a drag keeps the popup inside, in client px. */
export type PopupResizeBound = { left: number; right: number; top?: number; bottom: number };

export interface PopupResizeDrag {
  /** The popup: its width is set, and it is moved (translate) so the anchor's edges stay put. Its
   *  parent is the positioner that places it. */
  popup: HTMLElement;
  /** The element whose height is set (default: the popup). */
  content?: HTMLElement;
  axes: PopupResizeAxes;
  /** The popup lines up with its anchor's end edge: its start (left) edge moves, the end stays. */
  fromEnd: boolean;
  /** The popup opens above its anchor: its top edge moves, the bottom stays. */
  fromTop: boolean;
  /** The narrowest and shortest a drag makes it, in px (less when the room is less). */
  least: { width: number; height: number };
  /** The room the popup may take, in client px. */
  bound: PopupResizeBound;
  /** A drag began: a render meanwhile must not reset the size it is setting. */
  onStart?(): void;
  /** The drag ended (pointer up or cancel). Each dimension it changed by a pixel or more carries the
   *  new size; one it did not change is undefined. */
  onEnd(size: { width?: number; height?: number }): void;
}

/// The room the positioner gives `popup`, in px: the --available-width and --available-height Base UI
/// sets on it. Infinite where it sets none (a popup no positioner sizes).
function availableRoom(positioner: HTMLElement, popup: HTMLElement): { width: number; height: number } {
  const computed = popup.ownerDocument.defaultView?.getComputedStyle(popup);
  const px = (name: string) => {
    const set = positioner.style.getPropertyValue(name) || computed?.getPropertyValue(name);
    const value = Number.parseFloat(set || "");
    return Number.isFinite(value) && value > 0 ? value : Infinity;
  };
  return { width: px("--available-width"), height: px("--available-height") };
}

/// Starts a resize drag from a press on `event.currentTarget` (a grip). Edge and corner drags share one
/// frame update and pin the sides nearest the anchor. False when the press does not start a drag (not
/// the primary button, no positioner).
export function startPopupResize(
  event: {
    button: number;
    clientX: number;
    clientY: number;
    pointerId?: number;
    currentTarget: EventTarget | null;
    preventDefault(): void;
    stopPropagation(): void;
  },
  drag: PopupResizeDrag,
): boolean {
  const { popup, axes, fromEnd, fromTop, bound } = drag;
  const content = drag.content ?? popup;
  const positioner = popup.parentElement;
  const grip = event.currentTarget as HTMLElement | null;
  if (event.button !== 0 || !positioner || !grip) return false;
  event.preventDefault();
  event.stopPropagation();
  const horizontal = axes !== "height";
  const vertical = axes !== "width";
  const view = popup.ownerDocument.defaultView;
  const start = popup.getBoundingClientRect();
  const startHeight = content.getBoundingClientRect().height;
  const startX = event.clientX;
  const startY = event.clientY;
  // Never more than the room the positioner gives the popup (Base UI's --available-width and -height,
  // inside its collision padding and boundary): the kept size is capped there when the drag ends
  // (PopupResize.tsx), so a drag that went past it would snap back (cmux#51745). Never less room than
  // the popup already has (a popup against the window's edge keeps its size), and never a floor above
  // where it started: a popup smaller than the floor (a one-row menu) does not jump up to it on a press.
  const room = availableRoom(positioner, popup);
  const mostWidth = Math.max(
    Math.floor(start.width),
    Math.floor(Math.min(fromEnd ? start.right - bound.left : bound.right - start.left, room.width)),
  );
  const leastWidth = Math.min(mostWidth, drag.least.width, Math.floor(start.width));
  // The room is the popup's; the height set is its content's, short of it by the popup's own chrome.
  const chrome = Math.max(0, start.height - startHeight);
  const roomHeight = fromTop ? start.bottom - (bound.top ?? 5) : bound.bottom - start.top;
  const mostHeight = Math.max(Math.floor(startHeight), Math.floor(Math.min(roomHeight, room.height - chrome)));
  const leastHeight = Math.min(mostHeight, drag.least.height, Math.floor(startHeight));
  let width = start.width;
  let height = startHeight;
  let dragging = true;
  const pin = () => {
    const wantedX = fromEnd ? start.right - width : start.left;
    const wantedY = vertical && fromTop ? start.bottom - popup.getBoundingClientRect().height : start.top;
    const placed = positioner.getBoundingClientRect();
    const x = horizontal ? Math.round((wantedX - placed.left) * 100) / 100 : 0;
    const y = vertical ? Math.round((wantedY - placed.top) * 100) / 100 : 0;
    popup.style.translate = x || y ? `${x}px ${y}px` : "";
    return x === 0 && y === 0;
  };
  // The positioner places the popup again for its new size a frame later: hold the pinned edges until
  // it has, then let go of the translate.
  const placed = new MutationObserver(() => {
    if (pin() && !dragging) placed.disconnect();
  });
  placed.observe(positioner, { attributes: true, attributeFilter: ["style"] });
  grip.setPointerCapture?.(event.pointerId ?? 0);
  grip.dataset.dragging = "";
  drag.onStart?.();
  let frame = 0;
  let pointerX = startX;
  let pointerY = startY;
  // A press with no move (a click, a double-click's first half) changes nothing.
  let moved = false;
  const apply = () => {
    frame = 0;
    if (horizontal) {
      const delta = (pointerX - startX) * (fromEnd ? -1 : 1);
      width = Math.round(Math.min(mostWidth, Math.max(leastWidth, start.width + delta)));
      popup.style.width = `${width}px`;
      popup.style.minWidth = `${leastWidth}px`;
      popup.style.maxWidth = `${mostWidth}px`;
    }
    if (vertical) {
      const delta = (pointerY - startY) * (fromTop ? -1 : 1);
      height = Math.round(Math.min(mostHeight, Math.max(leastHeight, startHeight + delta)));
      content.style.minHeight = "";
      content.style.height = `${height}px`;
      content.style.maxHeight = `${height}px`;
    }
    pin();
  };
  const move = (next: PointerEvent) => {
    pointerX = next.clientX;
    pointerY = next.clientY;
    moved ||= pointerX !== startX || pointerY !== startY;
    if (!moved) return;
    if (!frame) frame = view?.requestAnimationFrame(apply) ?? 0;
    if (!frame) apply();
  };
  const end = () => {
    if (frame) view?.cancelAnimationFrame(frame);
    if (moved) apply();
    grip.removeEventListener("pointermove", move);
    grip.removeEventListener("pointerup", end);
    grip.removeEventListener("pointercancel", end);
    delete grip.dataset.dragging;
    dragging = false;
    if (pin()) placed.disconnect();
    drag.onEnd({
      ...(horizontal && Math.abs(width - start.width) >= 1 ? { width } : {}),
      ...(vertical && Math.abs(height - startHeight) >= 1 ? { height } : {}),
    });
  };
  grip.addEventListener("pointermove", move);
  grip.addEventListener("pointerup", end);
  grip.addEventListener("pointercancel", end);
  return true;
}
