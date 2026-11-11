// The New Tab page's edit mode (Leo 2026-10-20, as editing an iPhone's home screen): right-click the
// page and choose Edit New Tab, and its widgets wiggle. Drag one to move it, or focus it and press
// Option-Up or Option-Down; its ✕ (or Delete) turns it off; Add Widgets opens a menu of the widgets,
// where a row turns one on; Done or Escape ends it. Every edit is saved as
// Settings would save it (`tabs.newTabWidgets.*`, pageWidgets.ts editNewTabWidgets). The wiggle is
// motion: Reduce Motion and the animation switches (`data-agent-motion="off"`) keep the widgets still.
import { type DragEvent, type KeyboardEvent, type ReactNode, useState } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { Icon } from "../icons/Icon";
import { droppedWidget, movedWidget, type MovableWidget, type PageWidget, type WidgetEdit } from "./pageWidgets";
import { useNt } from "./strings";
import { useWidgetName, useWidgetEditing } from "./widgetEditingModel";
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
        <Icon name="action.close" size={12} />
      </button>
    </div>
  );
}

/// `order` with `id` moved `by` places (-1 earlier, 1 later), clamped to the row.
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

const GRID_DRAG_TYPE = "application/x-cmux-grid-widget";

/// One cell of the widget row (a built-in clock, timer, greeting or quote, or an app's widget) in edit
/// mode: it wiggles as the page's other widgets do, takes a drag along the row and Option-Left or
/// Option-Right, and closes with its ✕ or Delete. The row's order is the daemon's New Tab layout.
export function GridWidgetFrame({
  id,
  label,
  order,
  editing,
  className,
  onRemove,
  onMove,
  children,
}: {
  id: string;
  label: string;
  /// Every cell of the row, in order.
  order: readonly string[];
  editing: WidgetEditing;
  className?: string;
  onRemove(): void;
  onMove(order: string[]): void;
  children: ReactNode;
}) {
  const nt = useNt();
  const [drop, setDrop] = useState<"before" | "after">();
  const [dragging, setDragging] = useState(false);
  if (!editing.editing) return <>{children}</>;
  const move = (next: string[]) => {
    if (next.join("\n") !== order.join("\n")) onMove(next);
  };
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.target !== event.currentTarget) return;
    if (event.key === "Delete" || event.key === "Backspace") {
      event.preventDefault();
      onRemove();
    } else if (event.altKey && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
      event.preventDefault();
      move(movedCell(order, id, event.key === "ArrowLeft" ? -1 : 1));
      // The move draws the cell in a new place: keep the keyboard on it.
      const page = event.currentTarget.ownerDocument;
      requestAnimationFrame(() =>
        page.querySelector<HTMLElement>(`.nt-widget-frame[data-cell="${CSS.escape(id)}"]`)?.focus(),
      );
    }
  };
  return (
    <div
      className={className ? `${className} nt-widget-frame nt-grid-frame` : "nt-widget-frame nt-grid-frame"}
      data-editing=""
      data-cell={id}
      data-dragging={dragging || undefined}
      data-drop={drop}
      // A sortable item, as WidgetFrame: a movable widget with its keys on it.
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="button" // ui-allow: a sortable item (dnd lists' pattern); no ui primitive moves items yet.
      tabIndex={0} // ui-allow: each edited widget is a Tab stop, so the keyboard can move and remove it.
      aria-label={label}
      aria-roledescription={nt("edit.widget")}
      onKeyDown={onKeyDown} // ui-allow: Option-Left, Option-Right and Delete on the focused widget.
      draggable
      onDragStart={(event) => {
        event.dataTransfer.effectAllowed = "move";
        // Not text/plain: a drop on the composer must not type the widget's id.
        event.dataTransfer.setData(GRID_DRAG_TYPE, id);
        setDragging(true);
      }}
      onDragOver={(event) => {
        if (!event.dataTransfer.types.includes(GRID_DRAG_TYPE)) return;
        event.preventDefault();
        const box = event.currentTarget.getBoundingClientRect();
        const next = event.clientX > box.left + box.width / 2 ? "after" : "before";
        if (next !== drop) setDrop(next);
      }}
      onDragLeave={() => setDrop(undefined)}
      onDrop={(event) => {
        event.preventDefault();
        const held = event.dataTransfer.getData(GRID_DRAG_TYPE);
        if (held) move(droppedCell(order, held, id, drop === "after"));
        setDrop(undefined);
      }}
      onDragEnd={() => {
        setDragging(false);
        setDrop(undefined);
      }}
    >
      <div className="nt-widget-content" inert>
        {children}
      </div>
      <button
        type="button"
        className="nt-widget-remove"
        aria-label={nt("edit.remove", { name: label })}
        title={nt("edit.remove", { name: label })}
        onClick={onRemove}
      >
        <Icon name="action.close" size={12} />
      </button>
    </div>
  );
}

/// The built-in widgets Add Widgets lists, in the menu's order.
const ADDABLE_WIDGETS: readonly PageWidget[] = [
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
];

/// An app's widget Add Widgets offers (ExtensionWidgets.tsx): placing it adds it to the row's end.
export type AddableWidget = { id: string; title: string };

/// The bar over the page while it is edited: Add Widgets and Done.
export function WidgetEditBar({
  editing,
  onEdit,
  apps = [],
  onAddApp,
}: {
  editing: WidgetEditing;
  onEdit(edit: WidgetEdit): void;
  /// Installed apps' widgets not on the page, listed after the built-in ones.
  apps?: readonly AddableWidget[];
  onAddApp?(id: string): void;
}) {
  const nt = useNt();
  const widgetName = useWidgetName();
  if (!editing.editing) return null;
  return (
    <div className="nt-edit-bar">
      {/* ui/Menu owns the roles, the arrow keys, typeahead, Escape and where focus goes back. Its popup is
          in the page only while it is open, so the page's Escape (useWidgetEditing) stands down for it
          and the next Escape ends edit mode. */}
      <Menu>
        <MenuButton className="nt-edit-button" data-menu="newtab-add-widget" aria-haspopup="menu">
          <Icon name="action.add" size={12} />
          <span>{nt("edit.add")}</span>
        </MenuButton>
        <MenuPopup label={nt("edit.add")} className="acpmux-quick-menu nt-edit-add-menu" align="end">
          {ADDABLE_WIDGETS.map((widget) => (
            <MenuItem
              key={widget}
              className="acpmux-quick-item"
              data-value={widget}
              onSelect={() => onEdit({ edit: "show", widget })}
            >
              {widgetName(widget)}
            </MenuItem>
          ))}
          {onAddApp &&
            apps.map((app) => (
              <MenuItem
                key={app.id}
                className="acpmux-quick-item"
                data-value={app.id}
                onSelect={() => onAddApp(app.id)}
              >
                {app.title}
              </MenuItem>
            ))}
        </MenuPopup>
      </Menu>
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
