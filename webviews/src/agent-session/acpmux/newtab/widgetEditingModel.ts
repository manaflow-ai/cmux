import { useEffect, useState } from "react";
import { type MovableWidget, type PageWidget, type WidgetEdit } from "./pageWidgets";
import { useNt } from "./strings";

/// A widget's name, for its ✕ and the screen reader.
export function useWidgetName(): (widget: PageWidget) => string {
  const nt = useNt();
  return (widget) =>
    widget === "greeting"
      ? nt("widget.headline")
      : widget === "projects"
        ? nt("widget.projects")
        : widget === "actions"
          ? nt("widget.actions")
          : widget === "chats"
            ? nt("widget.chats")
            : widget === "clock"
              ? nt("widget.clock")
              : widget === "timer"
                ? nt("widget.timer")
                : widget === "warmGreeting"
                  ? nt("widget.warmGreeting")
                  : widget === "quote"
                    ? nt("widget.quote")
                    : widget;
}

/// Where a drag is: the widget held, and the one it would land before or after.
type DragState = { widget: MovableWidget; over?: MovableWidget; after?: boolean };

/// The edit mode's state: whether it is on, and the drag in flight.
export function useWidgetEditing(onEdit: ((edit: WidgetEdit) => void) | undefined) {
  const [editing, setEditing] = useState(false);
  const [drag, setDrag] = useState<DragState | undefined>();
  // A page that loses its edit mode (another layout) leaves it.
  if (editing && !onEdit) setEditing(false);
  useEffect(() => {
    if (!editing || !onEdit) return;
    const listener = (event: globalThis.KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      // An open menu, list or picker takes its own Escape first.
      if (document.querySelector('[role="menu"], [role="listbox"], [role="dialog"], .ui-popup')) return;
      event.preventDefault();
      setEditing(false);
    };
    // ui-allow: Escape ends the edit mode wherever focus is on the page, as Done does.
    document.addEventListener("keydown", listener);
    return () => document.removeEventListener("keydown", listener);
  }, [editing, onEdit]);
  return { editing: editing && !!onEdit, setEditing, drag, setDrag };
}
