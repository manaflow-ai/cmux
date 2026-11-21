// The New Tab widget grid's edit mode (Apple's: Edit Widgets, then the tiles jiggle, each with its
// minus badge, a size menu and a drag to arrange; Done or Escape ends it). Restored from the page's
// earlier edit mode (4f3b29a4073c^ widgetEditingModel.ts and WidgetEditing.tsx's movedCell and
// droppedCell); the layout itself is the daemon's (`apps.widgets.layout.edit`), never the page's.
import { useEffect, useState } from "react";

/// `order` with `id` moved `by` places (-1 earlier, 1 later), clamped to the grid.
export function movedCell(order: readonly string[], id: string, by: number): string[] {
  const from = order.indexOf(id);
  if (from < 0) return [...order];
  const next = order.filter((item) => item !== id);
  next.splice(Math.max(0, Math.min(order.length - 1, from + by)), 0, id);
  return next;
}

/// `order` with `id` dropped before `target` (or after it, `after`).
export function droppedCell(order: readonly string[], id: string, target: string, after: boolean): string[] {
  if (id === target || !order.includes(id)) return [...order];
  const next = order.filter((item) => item !== id);
  next.splice(next.indexOf(target) + (after ? 1 : 0), 0, id);
  return next;
}

/// The daemon's `move {instance, before?}` that turns `order` into `next` for the tile that moved:
/// it goes before the tile after it in `next` (the end when it is last). Undefined when nothing moved.
export function moveEdit(
  order: readonly string[],
  next: readonly string[],
  id: string,
): { op: "move"; instance: string; before?: string } | undefined {
  if (order.join("\n") === next.join("\n")) return undefined;
  const before = next[next.indexOf(id) + 1];
  return before ? { op: "move", instance: id, before } : { op: "move", instance: id };
}

/// Whether the grid is in edit mode; Escape ends it unless a menu, list or sheet takes it first.
export function useWidgetEditing(initial = false) {
  const [editing, setEditing] = useState(initial);
  useEffect(() => {
    if (!editing) return;
    const listener = (event: globalThis.KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      // An open menu, list or sheet takes its own Escape first.
      if (document.querySelector('[role="menu"], [role="listbox"], [role="dialog"], .ui-popup')) return;
      event.preventDefault();
      setEditing(false);
    };
    // ui-allow: Escape ends the edit mode wherever focus is on the page, as Done does.
    document.addEventListener("keydown", listener);
    return () => document.removeEventListener("keydown", listener);
  }, [editing]);
  return { editing, setEditing };
}
export type WidgetEditing = ReturnType<typeof useWidgetEditing>;
