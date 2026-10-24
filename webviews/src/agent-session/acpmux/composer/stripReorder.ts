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

/// The index a chip dragged to `x` goes to, among `centers` (the other chips' horizontal centers,
/// left to right, the dragged one left out).
export function dropIndex(x: number, centers: readonly number[]): number {
  const before = centers.findIndex((center) => x < center);
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
      if (!press.dragged) {
        if (Math.hypot(event.clientX - press.x, event.clientY - press.y) < DRAG_SLOP_PX) return;
        press.dragged = true;
        strip.setPointerCapture?.(event.pointerId);
        setDragging(press.id);
      }
      event.preventDefault();
      const { ids: order, onReorder: reorder } = live.current;
      const index = dropIndex(event.clientX, centers(press.id));
      if (order.indexOf(press.id) !== index) reorder?.(press.id, index);
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
      const index = order.indexOf(id) + (event.key === "ArrowLeft" ? -1 : 1);
      if (index >= 0 && index < order.length) reorder(id, index);
    };
    strip.addEventListener("pointerdown", down);
    strip.addEventListener("pointermove", move);
    strip.addEventListener("pointerup", up);
    strip.addEventListener("pointercancel", up);
    strip.addEventListener("keydown", key);
    return () => {
      strip.removeEventListener("pointerdown", down);
      strip.removeEventListener("pointermove", move);
      strip.removeEventListener("pointerup", up);
      strip.removeEventListener("pointercancel", up);
      strip.removeEventListener("keydown", key);
    };
  }, [strip]);
  return { ref: setStrip, dragging };
}
