// The New Tab page's edit mode (Leo 2026-10-20, as editing an iPhone's home screen): right-click the
// page and choose Edit New Tab, and its widgets wiggle. Drag one to move it, or focus it and press
// Option-Up or Option-Down; its ✕ (or Delete) turns it off; Add Widgets opens a menu of the widgets,
// where a row turns one on; Done or Escape ends it. Every edit is saved as
// Settings would save it (`tabs.newTabWidgets.*`, pageWidgets.ts editNewTabWidgets). The wiggle is
// motion: Reduce Motion and the animation switches (`data-agent-motion="off"`) keep the widgets still.
import { type DragEvent, type KeyboardEvent, type ReactNode, useEffect, useState } from "react";
import { Icon } from "../icons/Icon";
import { droppedWidget, movedWidget, type MovableWidget, type PageWidget, type WidgetEdit } from "./pageWidgets";
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

export type WidgetEditing = ReturnType<typeof useWidgetEditing>;

/// One widget on the page. Out of edit mode it is its content only; in edit mode it wiggles, takes
/// a drag and the keyboard, and shows its ✕.
export function WidgetFrame({
  widget,
  editing,
  order,
  onEdit,
  className,
  children,
}: {
  widget: PageWidget;
  editing: WidgetEditing;
  /// The movable widgets shown, in order; a widget not in it (the headline) stays where it is.
  order: readonly MovableWidget[];
  onEdit?(edit: WidgetEdit): void;
  className?: string;
  children: ReactNode;
}) {
  const name = useWidgetName();
  const nt = useNt();
  if (!editing.editing || !onEdit) return <div className={className}>{children}</div>;
  const movable = (order as readonly PageWidget[]).includes(widget) ? (widget as MovableWidget) : undefined;
  const { drag, setDrag } = editing;
  const remove = () => onEdit({ edit: "remove", widget });
  const move = (next: MovableWidget[]) => {
    if (next.join() !== order.join()) onEdit({ edit: "order", order: next });
  };
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.target !== event.currentTarget) return;
    if (event.key === "Delete" || event.key === "Backspace") {
      event.preventDefault();
      remove();
    } else if (movable && event.altKey && (event.key === "ArrowUp" || event.key === "ArrowDown")) {
      event.preventDefault();
      move(movedWidget(order, movable, event.key === "ArrowUp" ? -1 : 1));
      // The move may draw the widget in another cards column (a new element): keep the keyboard on it.
      const page = event.currentTarget.ownerDocument;
      requestAnimationFrame(() =>
        page.querySelector<HTMLElement>(`.nt-widget-frame[data-widget="${movable}"]`)?.focus(),
      );
    }
  };
  const dragProps = movable
    ? {
        draggable: true,
        onDragStart: (event: DragEvent<HTMLDivElement>) => {
          event.dataTransfer.effectAllowed = "move";
          // Not text/plain: a drop on the composer must not type the widget's name.
          event.dataTransfer.setData("application/x-cmux-widget", movable);
          setDrag({ widget: movable });
        },
        onDragOver: (event: DragEvent<HTMLDivElement>) => {
          if (!drag) return;
          event.preventDefault();
          const box = event.currentTarget.getBoundingClientRect();
          const after = event.clientY > box.top + box.height / 2;
          if (drag.over !== movable || drag.after !== after) setDrag({ ...drag, over: movable, after });
        },
        onDrop: (event: DragEvent<HTMLDivElement>) => {
          event.preventDefault();
          if (drag) move(droppedWidget(order, drag.widget, movable, drag.after ?? false));
          setDrag(undefined);
        },
        onDragEnd: () => setDrag(undefined),
      }
    : {};
  return (
    <div
      className={className ? `${className} nt-widget-frame` : "nt-widget-frame"}
      data-editing=""
      data-widget={widget}
      data-dragging={drag?.widget === widget || undefined}
      data-drop={drag && drag.over === widget && drag.widget !== widget ? (drag.after ? "after" : "before") : undefined}
      // A sortable item, as drag-and-drop lists name one: a button the screen reader calls a
      // movable widget, with its keys (Option-Up, Option-Down, Delete) on it. Not a <button>: it
      // holds the widget and its own ✕ button.
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="button" // ui-allow: a sortable item (dnd lists' pattern); no ui primitive moves items yet.
      tabIndex={0} // ui-allow: each edited widget is a Tab stop, so the keyboard can move and remove it.
      aria-label={name(widget)}
      aria-roledescription={nt("edit.widget")}
      onKeyDown={onKeyDown} // ui-allow: Option-Up, Option-Down and Delete on the focused widget.
      {...dragProps}
    >
      <div className="nt-widget-content" inert>
        {children}
      </div>
      <button
        type="button"
        className="nt-widget-remove"
        aria-label={nt("edit.remove", { name: name(widget) })}
        title={nt("edit.remove", { name: name(widget) })}
        onClick={remove}
      >
        <Icon name="action.close" size={10} />
      </button>
    </div>
  );
}

/// The bar over the page while it is edited: Add Widgets and Done.
export function WidgetEditBar({ editing, onEdit }: { editing: WidgetEditing; onEdit(edit: WidgetEdit): void }) {
  const nt = useNt();
  const widgetName = useWidgetName();
  // The widget menu exists only while it is open: the page's Escape stands down for any open menu
  // (useWidgetEditing), so a closed one left in the DOM kept Escape from ever ending edit mode.
  const [adding, setAdding] = useState(false);
  useEffect(() => {
    if (!adding) return;
    const listener = (event: globalThis.KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      event.preventDefault();
      setAdding(false);
    };
    // ui-allow: Escape closes the open widget menu first, wherever focus is; the next ends edit mode.
    document.addEventListener("keydown", listener);
    return () => document.removeEventListener("keydown", listener);
  }, [adding]);
  if (!editing.editing) return null;
  return (
    <div className="nt-edit-bar">
      <details className="nt-edit-add" open={adding}>
        <summary
          className="nt-edit-button"
          data-edit="add"
          // The page owns the disclosure (the native toggle event comes a task late).
          onClick={(event) => {
            event.preventDefault();
            setAdding((open) => !open);
          }}
        >
          <Icon name="action.add" size={12} />
          <span>{nt("edit.add")}</span>
        </summary>
        {adding && (
          <div className="nt-edit-add-menu" role="menu">
            {(
              [
                "greeting",
                "clock",
                "timer",
                "warmGreeting",
                "quote",
                "projects",
                "actions",
                "chats",
                "styleDots",
                "weather",
                "machines",
              ] as PageWidget[]
            ).map((widget) => (
              <button
                key={widget}
                type="button"
                role="menuitem"
                onClick={() => {
                  setAdding(false);
                  onEdit({ edit: "show", widget });
                }}
              >
                {widgetName(widget)}
              </button>
            ))}
          </div>
        )}
      </details>
      <button
        type="button"
        className="nt-edit-button"
        data-edit="done"
        data-primary=""
        onClick={() => editing.setEditing(false)}
      >
        {nt("edit.done")}
      </button>
    </div>
  );
}
