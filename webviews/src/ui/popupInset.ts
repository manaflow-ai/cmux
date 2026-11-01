// The top of the page a portaled popup must keep clear of: the pane's native tab row draws over it
// while a chat's header tools sit in that row (acpmux header/tabRow.ts). A menu that reached into it
// opened under the tabs with its top cut off (Leo 2026-10-25: "why is the top part cut off? ... it's
// cut off because there's some stuff at the top right").
import { useMemo, useSyncExternalStore } from "react";

/// Base UI's own `collisionPadding`, kept on every other edge.
const EDGE = 5;

let insetTop = 0;
const listeners = new Set<() => void>();

/// The height, in CSS pixels, drawn over at the page's top; 0 when nothing is.
export function setPopupInsetTop(height: number): void {
  const next = Number.isFinite(height) && height > 0 ? height : 0;
  if (next === insetTop) return;
  insetTop = next;
  for (const listener of listeners) listener();
}

const read = () => insetTop;
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// Base UI's `collisionPadding` for a portaled popup: its default on every edge, past the inset at the top.
export function usePopupPadding(): { top: number; right: number; bottom: number; left: number } {
  const top = useSyncExternalStore(subscribe, read, read);
  return useMemo(() => ({ top: top + EDGE, right: EDGE, bottom: EDGE, left: EDGE }), [top]);
}
