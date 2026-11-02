// Dragging a staged chip along the attachment strip moves it, and the prompt sends its attachments
// in the strip's order (Leo, 2026-10-24: "we ought to be able to drag and reorder images if we're
// seeing the non-inline attachment composer"). Pointer events, not HTML drag and drop: a drag here
// never carries files, so the page's file drop (attachments.ts installFileDropLifecycle) and its
// overlay never see it. Option-Left and Option-Right move the focused chip from the keyboard.
//
// It looks like a drag and drop (Leo, 2026-10-26: "there's no click-and-drag animation or whatever.
// Like, it has to just look like a drag-and-drop"): the lifted chip rides under the pointer, the
// chips it passes slide out of its way, and on release it settles into its slot. Reduce Motion keeps
// the chip under the pointer and the jump, with no slide or settle.
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { reducedMotion } from "../threadMinimap/scrollMotion";

/// How far the pointer moves before a press becomes a drag; less is a click (open, remove).
export const DRAG_SLOP_PX = 4;

/// The slot of each staged chip in the strip: `data-attachment-index`, its chip inside it (an index,
/// so the page never carries a chip's id, which may hold a file's name).
const SLOT = "[data-attachment-index]";

/// The index a chip dragged to `x` goes to, among `centers` (the other chips' horizontal centers in
/// the strip's order, the dragged one left out). Right to left the strip's order runs leftward.
export function dropIndex(x: number, centers: readonly number[], rtl = false): number {
  const before = centers.findIndex((center) => (rtl ? x > center : x < center));
  return before < 0 ? centers.length : before;
}

/// How long a passed chip slides to its new slot, and the dragged one settles into its own.
export const SLIDE_MS = 160;
const SLIDE_EASING = "cubic-bezier(0.2, 0, 0, 1)";

/// How far the dragged chip sits from its slot so it stays under the pointer: the pointer at
/// `pointerX`, grabbed `grab` from the chip's left edge, the slot's left edge at `slotLeft`. It stays
/// inside the strip (`min`..`max`, its edges, which clip what overflows), `width` being its own.
export function followOffset(
  pointerX: number,
  grab: number,
  slotLeft: number,
  width: number,
  min: number,
  max: number,
): number {
  const left = Math.max(min, Math.min(pointerX - grab, max - width));
  return left - slotLeft;
}

/// Each chip that moved between two layouts and how far: `before` and `after` are left edges by id.
/// The slide starts a chip `delta` back from its new slot and runs to it.
export function slides(
  before: ReadonlyMap<string, number>,
  after: ReadonlyMap<string, number>,
  skip?: string,
): { id: string; delta: number }[] {
  const out: { id: string; delta: number }[] = [];
  for (const [id, left] of after) {
    const was = before.get(id);
    if (id === skip || was === undefined) continue;
    const delta = was - left;
    if (Math.abs(delta) >= 0.5) out.push({ id, delta });
  }
  return out;
}

/// The settle running on a chip, so the next drag can stop it (and only it) when it picks the chip up.
const settling = new WeakMap<HTMLElement, Animation>();

/// The chip inside a slot: what moves on screen (the slot itself draws nothing, display: contents).
const chipOf = (slot: HTMLElement) => (slot.querySelector<HTMLElement>(".acpmux-attachment") ?? slot);

/// Each staged chip of `strip` by id, in the strip's order.
function chipsById(strip: HTMLElement, ids: readonly string[]): Map<string, HTMLElement> {
  const chips = new Map<string, HTMLElement>();
  for (const slot of strip.querySelectorAll<HTMLElement>(SLOT)) {
    const id = ids[Number(slot.dataset.attachmentIndex)];
    if (id !== undefined) chips.set(id, chipOf(slot));
  }
  return chips;
}

/// How far `chip` is drawn from its slot now: the drag's own offset plus any slide still running
/// (its computed `translate`), 0 when none.
function translateOf(chip: HTMLElement): number {
  return Number.parseFloat(getComputedStyle(chip).translate) || 0;
}

/// Each chip's left edge where its slot puts it (a running slide and the dragged chip's offset left
/// out). Slides run additively (composite "add"), so one that starts from a slot measured this way
/// takes over from a slide still running without a jump.
function slotLefts(chips: ReadonlyMap<string, HTMLElement>): Map<string, number> {
  const lefts = new Map<string, number>();
  for (const [id, chip] of chips) lefts.set(id, chip.getBoundingClientRect().left - translateOf(chip));
  return lefts;
}

/// `ids` with `id` moved to `index` (counted without it).
export function moved(ids: readonly string[], id: string, index: number): string[] {
  const rest = ids.filter((other) => other !== id);
  if (rest.length === ids.length) return [...ids];
  rest.splice(Math.max(0, Math.min(index, rest.length)), 0, id);
  return rest;
}

/// `list` with the attachment `id` moved to `index`: what a strip's `onReorder` does to the chips.
export function reordered<T extends { id: string }>(list: readonly T[], id: string, index: number): T[] {
  const byId = new Map(list.map((item) => [item.id, item]));
  return moved(
    list.map((item) => item.id),
    id,
    index,
  ).map((key) => byId.get(key)!);
}

/// Wires the strip's drag to reorder. `onReorder(id, index)` moves a chip (unset: chips stay put).
/// Returns the ref for the strip and the id of the chip being dragged.
export function useStripReorder(
  ids: readonly string[],
  onReorder?: (id: string, index: number) => void,
): { ref: (element: HTMLElement | null) => void; dragging: string | undefined } {
  const [strip, setStrip] = useState<HTMLElement | null>(null);
  const [dragging, setDragging] = useState<string>();
  const live = useRef({ ids, onReorder });
  live.current = { ids, onReorder };
  /// The drag on screen: the chip that rides the pointer, where the pointer is, and where it was
  /// grabbed (from the chip's left edge).
  const ride = useRef<{ id: string; pointerX: number; grab: number }>(undefined);
  /// Every chip's slot before the move just asked for (a drag's or the arrows'), for the slides.
  const before = useRef<Map<string, number>>(undefined);
  /// Puts the dragged chip under the pointer from wherever its slot is now.
  const follow = useRef<() => void>(() => {});
  follow.current = () => {
    const drag = ride.current;
    if (!strip || !drag) return;
    const chip = chipsById(strip, live.current.ids).get(drag.id);
    if (!chip) return;
    const box = chip.getBoundingClientRect();
    const bounds = strip.getBoundingClientRect();
    const offset = followOffset(drag.pointerX, drag.grab, box.left - translateOf(chip), box.width, bounds.left, bounds.right);
    chip.style.translate = `${offset}px 0`;
  };
  // A move re-lays the strip: the chips the dragged one passed slide from their old slots to their
  // new ones, and the dragged one stays under the pointer.
  const order = ids.join("\u0000");
  useLayoutEffect(() => {
    const was = before.current;
    before.current = undefined;
    if (!strip || !was) return;
    const chips = chipsById(strip, live.current.ids);
    if (!reducedMotion())
      for (const { id, delta } of slides(was, slotLefts(chips), ride.current?.id))
        chips.get(id)?.animate?.([{ translate: `${delta}px 0` }, { translate: "0 0" }], {
          duration: SLIDE_MS,
          easing: SLIDE_EASING,
          composite: "add",
        });
    follow.current();
  }, [order, strip]);
  useEffect(() => {
    if (!strip) return;
    let press: { id: string; x: number; y: number; pointer: number; dragged: boolean } | undefined;
    const slotOf = (target: EventTarget | null) =>
      target instanceof Element ? (target.closest(SLOT) as HTMLElement | null) : null;
    const idOf = (slot: HTMLElement | null) =>
      slot ? live.current.ids[Number(slot.dataset.attachmentIndex)] : undefined;
    // The other chips' centers where their slots put them: a chip mid-slide counts at its new slot.
    const centers = (skip: string) =>
      [...strip.querySelectorAll<HTMLElement>(SLOT)]
        .filter((slot) => idOf(slot) !== skip)
        .map((slot) => {
          const chip = chipOf(slot);
          const box = chip.getBoundingClientRect();
          return box.left - translateOf(chip) + box.width / 2;
        });
    // Release: the dragged chip glides from under the pointer into its slot.
    const settle = (id: string) => {
      ride.current = undefined;
      const chip = chipsById(strip, live.current.ids).get(id);
      if (!chip) return;
      const offset = Number.parseFloat(chip.style.translate) || 0;
      chip.style.translate = "";
      if (!offset || reducedMotion() || !chip.animate) return;
      const animation = chip.animate([{ translate: `${offset}px 0` }, { translate: "0 0" }], {
        duration: SLIDE_MS,
        easing: SLIDE_EASING,
        composite: "add",
      });
      settling.set(chip, animation);
    };
    const down = (event: PointerEvent) => {
      if (!live.current.onReorder || event.button !== 0 || live.current.ids.length < 2) return;
      const id = idOf(slotOf(event.target));
      if (!id) return;
      press = { id, x: event.clientX, y: event.clientY, pointer: event.pointerId, dragged: false };
    };
    const move = (event: PointerEvent) => {
      if (!press || event.pointerId !== press.pointer) return;
      // Released where the strip never heard it: the press is over.
      if (event.buttons === 0) return end();
      if (!press.dragged) {
        if (Math.hypot(event.clientX - press.x, event.clientY - press.y) < DRAG_SLOP_PX) return;
        press.dragged = true;
        try {
          strip.setPointerCapture?.(event.pointerId);
        } catch {
          // No active pointer to capture (a synthetic one): the drag goes on without capture.
        }
        const chip = chipsById(strip, live.current.ids).get(press.id);
        // A settle still running from the last drag stops: the chip is picked up where it is drawn.
        if (chip) settling.get(chip)?.finish();
        const left = chip ? chip.getBoundingClientRect().left : press.x;
        ride.current = { id: press.id, pointerX: event.clientX, grab: press.x - left };
        setDragging(press.id);
      }
      event.preventDefault();
      const drag = ride.current;
      if (drag) drag.pointerX = event.clientX;
      const { ids: order, onReorder: reorder } = live.current;
      const rtl = getComputedStyle(strip).direction === "rtl";
      const index = dropIndex(event.clientX, centers(press.id), rtl);
      if (order.indexOf(press.id) !== index && reorder) {
        // Where every chip sits before the move, so the re-laid strip slides them from there.
        before.current = slotLefts(chipsById(strip, order));
        reorder(press.id, index);
      }
      follow.current();
    };
    const end = () => {
      if (press?.dragged) {
        settle(press.id);
        setDragging(undefined);
      }
      press = undefined;
    };
    const up = (event: PointerEvent) => {
      if (!press || event.pointerId !== press.pointer) return;
      if (press.dragged) {
        // The press was a drag: the click it ends with opens nothing and removes nothing.
        const swallow = (click: MouseEvent) => {
          click.stopPropagation();
          click.preventDefault();
        };
        strip.addEventListener("click", swallow, { capture: true, once: true });
        setTimeout(() => strip.removeEventListener("click", swallow, { capture: true }), 0);
        settle(press.id);
        setDragging(undefined);
      }
      press = undefined;
    };
    const key = (event: KeyboardEvent) => {
      if (!event.altKey || (event.key !== "ArrowLeft" && event.key !== "ArrowRight")) return;
      const id = idOf(slotOf(event.target));
      const { ids: order, onReorder: reorder } = live.current;
      if (!id || !reorder) return;
      event.preventDefault();
      // The arrow's way on screen: right to left, Option-Left moves a chip later in the strip.
      const earlier = (event.key === "ArrowLeft") !== (getComputedStyle(strip).direction === "rtl");
      const index = order.indexOf(id) + (earlier ? -1 : 1);
      if (index < 0 || index >= order.length) return;
      before.current = slotLefts(chipsById(strip, order));
      reorder(id, index);
    };
    strip.addEventListener("pointerdown", down);
    strip.addEventListener("pointermove", move);
    strip.addEventListener("pointerup", up);
    strip.addEventListener("pointercancel", up);
    strip.addEventListener("keydown", key);
    // A press that ends outside the strip, or a window that loses focus mid-press, ends it too.
    const view = strip.ownerDocument.defaultView;
    const away = (event: PointerEvent) => {
      if (press && event.pointerId === press.pointer && !strip.contains(event.target as Node)) end();
    };
    view?.addEventListener("pointerup", away, true);
    view?.addEventListener("pointercancel", away, true);
    view?.addEventListener("blur", end);
    return () => {
      view?.removeEventListener("pointerup", away, true);
      view?.removeEventListener("pointercancel", away, true);
      view?.removeEventListener("blur", end);
      strip.removeEventListener("pointerdown", down);
      strip.removeEventListener("pointermove", move);
      strip.removeEventListener("pointerup", up);
      strip.removeEventListener("pointercancel", up);
      strip.removeEventListener("keydown", key);
    };
  }, [strip]);
  return { ref: setStrip, dragging };
}
