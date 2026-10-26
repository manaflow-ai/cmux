// Dragging a staged chip along the attachment strip moves it, and the prompt sends its attachments
// in the strip's order (Leo, 2026-10-24: "we ought to be able to drag and reorder images if we're
// seeing the non-inline attachment composer"). Pointer events, not HTML drag and drop: a drag here
// never carries files, so the page's file drop (attachments.ts installFileDropLifecycle) and its
// overlay never see it. Option-Left and Option-Right move the focused chip from the keyboard.
import { useEffect, useRef, useState } from "react";

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
  useEffect(() => {
    if (!strip) return;
    let press: { id: string; x: number; y: number; pointer: number; dragged: boolean } | undefined;
    const slotOf = (target: EventTarget | null) =>
      target instanceof Element ? (target.closest(SLOT) as HTMLElement | null) : null;
    const idOf = (slot: HTMLElement | null) =>
      slot ? live.current.ids[Number(slot.dataset.attachmentIndex)] : undefined;
    const centers = (skip: string) =>
      [...strip.querySelectorAll<HTMLElement>(SLOT)]
        .filter((slot) => idOf(slot) !== skip)
        .map((slot) => {
          const box = (slot.querySelector(".acpmux-attachment") ?? slot).getBoundingClientRect();
          return box.left + box.width / 2;
        });
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
        setDragging(press.id);
      }
      event.preventDefault();
      const { ids: order, onReorder: reorder } = live.current;
      const rtl = getComputedStyle(strip).direction === "rtl";
      const index = dropIndex(event.clientX, centers(press.id), rtl);
      if (order.indexOf(press.id) !== index) reorder?.(press.id, index);
    };
    const end = () => {
      if (press?.dragged) setDragging(undefined);
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
      if (index >= 0 && index < order.length) reorder(id, index);
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
