// The Updated card's drag (Leo 2026-11-07: "what if you could, like, drag around the updated to
// nightly, and you can drag that up to the top if you wanted to?"). It uses the toasts' anchors and
// drag (ui/anchors.ts): a press on the card that moves up or down past the slop follows the
// pointer (across the line it still selects the words, u4466); let go, the card
// settles at the nearer of its two places, the bottom card slot or the top of the sidebar's list,
// and that place is remembered, so the card shows there next time. A flick, or a drop past the
// sidebar's edge, closes the card the way its x does.
//
// The page runs the drag; its host moves the card. In the sidebar the card's page is only as big as
// the card, so the native host moves its view by the offset the page reports and springs it to the
// new place (SidebarUpdatedCardHost+Drag.swift); in the gallery a stage moves it. The pointer is read
// in screen coordinates, so a view that moves under it never feeds back into the drag.
import { anchorMemory, anchorRow, createDrag, nearestAnchor, type Box, type Point } from "../../ui/anchors";

/** The card's two places in the sidebar: the bottom card slot (its first) or the top of the list. */
export type CardRow = "top" | "bottom";

/** How the held card feels (the toasts' three, ui/NoticeDeck.tsx): `spring` follows the pointer and
 *  settles on the spring; `rubber` leans part of the way toward the place it would settle at;
 *  `ghosts` is `spring` with both places outlined while it is held (where the host can draw them). */
export type CardDragFeel = "spring" | "rubber" | "ghosts";
/** The feel the sidebar ships (the gallery's pick). */
export const SHIPPED_DRAG_FEEL: CardDragFeel = "spring";

/** Where the card rests, as its host says: its place, and the room, CSS px, from its top edge up to
 *  the highest place it may rest and from its bottom edge down to the lowest. */
export interface CardPlace {
  anchor: CardRow;
  above: number;
  below: number;
  /** Points per CSS px (the page's zoom): the pointer's screen deltas are points. Absent: 1. */
  zoom?: number;
}

export interface CardDragHost {
  /** Where the card rests now; undefined while the host cannot move it (the card does not drag). */
  place(): CardPlace | undefined;
  /** The card is held this far from where it rests. */
  move(offset: Point): void;
  /** Let go: the card settles at `row`, from `offset`. */
  drop(row: CardRow, offset: Point): void;
  /** Flicked or dropped past the edge: the card closes (the x's path). */
  dismiss(): void;
  /** While held: the place the card would settle at; undefined once it is let go. */
  hold?(near: CardRow | undefined): void;
}

/** `rubber`: how much of the way toward its place a held card leans. */
export const RUBBER_LEAN = 0.3;

/** The card's place in the page's localStorage, as the toasts keep theirs (the bottom is stored as
 *  nothing). In the sidebar it mirrors the host's copy, the one that outlives the page (the page's
 *  storage is not persistent), which places the card's first frame after a relaunch. */
const memory = anchorMemory("cmux.sidebar.card.");
const MEMORY_KEY = "updated";

export function rememberedRow(store = memory): CardRow | undefined {
  const anchor = store.get(MEMORY_KEY);
  return anchor ? anchorRow(anchor) : undefined;
}

export function rememberRow(row: CardRow, store = memory): void {
  store.set(MEMORY_KEY, row === "top" ? "top" : "bottom");
}

/** The box the card may rest in, in the card's own coordinates at its rest (its top left at 0, 0). */
export function dragBox(place: CardPlace, width: number, height: number): Box {
  return { left: 0, top: 0 - place.above, width, height: place.above + height + place.below };
}

/** The offset that puts the card at `row`, from where it rests. */
export function rowOffset(row: CardRow, place: CardPlace): number {
  if (row === place.anchor) return 0;
  return row === "top" ? -place.above : place.below;
}

/** Where the held card is drawn for a pointer `offset`: there, or for `rubber`, leaned toward the
 *  place it would settle at. */
export function shownOffset(feel: CardDragFeel, offset: Point, row: CardRow, place: CardPlace): Point {
  if (feel !== "rubber") return offset;
  const target = { x: 0, y: rowOffset(row, place) };
  return { x: offset.x + (target.x - offset.x) * RUBBER_LEAN, y: offset.y + (target.y - offset.y) * RUBBER_LEAN };
}

/** Presses that never start a drag: the card's controls keep their own clicks. */
const CONTROLS = "button, a, input, [role='button']";

/** The press under way on each card (`pressCard`): its pointer, and how to end it. */
const pressed = new WeakMap<HTMLElement, { pointerId: number; end: (last: PointerEvent | null) => void }>();

/** Starts a drag of `card` (the card's body, its rest box) from `event`, a primary press on it. The
 *  press becomes a drag once it has moved past the slop up or down; across, it is left to select the
 *  card's words. `onStart` runs when it becomes a drag (the hover preview closes). */
export function pressCard(
  card: HTMLElement,
  event: PointerEvent,
  host: CardDragHost,
  feel: CardDragFeel,
  onStart: () => void,
): void {
  if (event.button !== 0 || (event.target as Element | null)?.closest?.(CONTROLS)) return;
  const target = event.currentTarget instanceof HTMLElement ? event.currentTarget : card;
  // One press per card: a second pointer pressed while one is active is not a drag of its own. The
  // same pointer pressing again means its release was missed (let go over the native sidebar, outside
  // the card-sized page view): that press ends there and this one starts (review F1 of #37802).
  const active = pressed.get(target);
  if (active && active.pointerId !== event.pointerId) return;
  active?.end(event);
  const place = host.place();
  if (!place) return;
  const rect = card.getBoundingClientRect();
  const start = { x: event.clientX - rect.left, y: event.clientY - rect.top };
  const screen = { x: event.screenX, y: event.screenY };
  const box = dragBox(place, rect.width, rect.height);
  const drag = createDrag(start, event.timeStamp);
  // Screen deltas are points; the card's offsets are CSS px at the page's zoom (review F3 of #37790).
  const zoom = place.zoom && place.zoom > 0 ? place.zoom : 1;
  const at = (next: PointerEvent): Point => ({
    x: start.x + (next.screenX - screen.x) / zoom,
    y: start.y + (next.screenY - screen.y) / zoom,
  });
  // The press listens on the page's window until it ends, so a release off the card before the slop
  // still ends it (review of #37669); the pointer is captured only once the press is a drag, so a
  // plain click and a selection across the words stay the page's own.
  const events: EventTarget = target.ownerDocument?.defaultView ?? target;
  let near: CardRow | undefined;
  let shown: Point = { x: 0, y: 0 };
  // Only the pointer that pressed moves or ends the press: a second touch or pen is not this drag.
  const own = (next: PointerEvent) => next.pointerId === event.pointerId;
  const move = (next: PointerEvent) => {
    if (!own(next)) return;
    // A release outside the card-sized page view (over the native sidebar) sends the page no
    // pointerup; the first move with no button held is the release.
    if (next.buttons === 0) {
      end(next, false);
      return;
    }
    const point = at(next);
    const offset = drag.move(point, next.timeStamp);
    if (!drag.dragging) return;
    if (target.dataset.dragging === undefined) {
      // Across the line selects the words, as it always has (u4466); up or down moves the card.
      if (Math.abs(offset.x) > Math.abs(offset.y)) {
        stop();
        return;
      }
      // The few pixels before the slop may have started a selection in the words: a drag is not one.
      target.dataset.dragging = "";
      target.setPointerCapture?.(next.pointerId);
      globalThis.getSelection?.()?.removeAllRanges();
      onStart();
    }
    const row = anchorRow(nearestAnchor(point, box));
    if (row !== near) {
      near = row;
      host.hold?.(row);
    }
    shown = shownOffset(feel, offset, row, place);
    host.move(shown);
  };
  const stop = () => {
    pressed.delete(target);
    events.removeEventListener("pointermove", move as EventListener);
    events.removeEventListener("pointerup", up as EventListener);
    events.removeEventListener("pointercancel", cancel as EventListener);
    events.removeEventListener("blur", blur);
  };
  /** Ends the press: let go at `last`, or with no event (the window lost focus) put back. */
  const end = (last: PointerEvent | null, cancelled: boolean) => {
    stop();
    if (target.hasPointerCapture?.(event.pointerId)) target.releasePointerCapture(event.pointerId);
    if (target.dataset.dragging === undefined) return;
    delete target.dataset.dragging;
    host.hold?.(undefined);
    const result = cancelled || !last ? null : drag.release(at(last), last.timeStamp, box);
    // The card lets go from where the pointer was released, not from the last move's place.
    if (result && last) shown = shownOffset(feel, drag.offset, anchorRow(nearestAnchor(at(last), box)), place);
    if (result?.kind === "dismiss") {
      host.dismiss();
      return;
    }
    const row = result?.kind === "snap" ? anchorRow(result.anchor) : place.anchor;
    if (row !== place.anchor) rememberRow(row);
    host.drop(row, shown);
  };
  const up = (last: PointerEvent) => {
    if (own(last)) end(last, false);
  };
  const cancel = (last: PointerEvent) => {
    if (own(last)) end(last, true);
  };
  // A window that loses focus mid-press hears no release: the press ends, the card put back.
  const blur = () => end(null, true);
  pressed.set(target, { pointerId: event.pointerId, end: (last) => end(last, false) });
  events.addEventListener("blur", blur);
  events.addEventListener("pointermove", move as EventListener);
  events.addEventListener("pointerup", up as EventListener);
  events.addEventListener("pointercancel", cancel as EventListener);
}
