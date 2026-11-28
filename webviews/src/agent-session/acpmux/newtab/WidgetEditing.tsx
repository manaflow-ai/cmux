// One tile of the New Tab widget grid in edit mode (restored from 4f3b29a4073c^ WidgetEditing.tsx's
// GridWidgetFrame): it jiggles (motion-gated in widgets.css), shows Apple's minus badge, picks its
// size from a menu (or the corner, or size chips, per the edit look), takes a drag along the grid and
// Option-Left or Option-Right, and closes with its minus or Delete. Every edit is the daemon's
// (`apps.widgets.layout.edit`); this only reads the gesture.
import { type KeyboardEvent, type ReactNode, useState } from "react";
import type { WidgetSize } from "../../../apps/scene/widgetsClient";
import { focusRoute } from "../../../ui/focusRoute";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../../ui/Menu";
import { Icon } from "../icons/Icon";
import { useNt } from "./strings";
import { useSizeName } from "./useSizeName";
import { droppedCell, movedCell } from "./widgetEditingModel";

/// How edit mode offers a resize: Apple's size menu (badge), a corner that steps to the next size
/// (corner), or the sizes as chips under the tile (chips).
export type WidgetEditLook = "badge" | "corner" | "chips";

const GRID_DRAG_TYPE = "application/x-cmux-grid-widget";

export function GridWidgetFrame({
  id,
  label,
  order,
  size,
  sizes,
  look,
  meter,
  onRemove,
  onMove,
  onResize,
  children,
}: {
  id: string;
  label: string;
  /// Every tile of the grid, in order.
  order: readonly string[];
  size: WidgetSize;
  /// The sizes the widget offers here.
  sizes: readonly WidgetSize[];
  look: WidgetEditLook;
  /// The edit mode's meter line (refresh interval, ticks, held batches).
  meter?: string | undefined;
  onRemove(): void;
  /// `instance` moved; `order` is the grid's order after it.
  onMove(instance: string, order: string[]): void;
  onResize(size: WidgetSize): void;
  children: ReactNode;
}) {
  const nt = useNt();
  const sizeName = useSizeName();
  const [drop, setDrop] = useState<"before" | "after">();
  const [dragging, setDragging] = useState(false);
  const move = (instance: string, next: string[]) => {
    if (next.join("\n") !== order.join("\n")) onMove(instance, next);
  };
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.target !== event.currentTarget) return;
    if (event.key === "Delete" || event.key === "Backspace") {
      event.preventDefault();
      onRemove();
    } else if (event.altKey && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
      event.preventDefault();
      move(id, movedCell(order, id, event.key === "ArrowLeft" ? -1 : 1));
      // The move draws the tile in a new place: keep the keyboard on it.
      const page = event.currentTarget.ownerDocument;
      requestAnimationFrame(() =>
        focusRoute(
          page.querySelector<HTMLElement>(`.nt-widget-frame[data-cell="${CSS.escape(id)}"]`),
          "person",
          "the widget the person moved with Option-arrow keeps the keyboard",
        ),
      );
    }
  };
  const next = sizes[(sizes.indexOf(size) + 1) % sizes.length] ?? size;
  const resizable = sizes.length > 1;
  return (
    <div
      className="nt-widget-frame"
      data-editing=""
      data-cell={id}
      data-size={size}
      data-dragging={dragging || undefined}
      data-drop={drop}
      // A sortable item, as drag-and-drop lists name one: a movable widget with its keys on it.
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="button" // ui-allow: a sortable item (dnd lists' pattern); no ui primitive moves items yet.
      tabIndex={0} // ui-allow: each edited widget is a Tab stop, so the keyboard can move and remove it.
      aria-label={label}
      aria-roledescription={nt("widgets.widget")}
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
        const side = event.clientX > box.left + box.width / 2 ? "after" : "before";
        if (side !== drop) setDrop(side);
      }}
      onDragLeave={() => setDrop(undefined)}
      onDrop={(event) => {
        event.preventDefault();
        const held = event.dataTransfer.getData(GRID_DRAG_TYPE);
        if (held) move(held, droppedCell(order, held, id, drop === "after"));
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
        aria-label={nt("widgets.remove", { name: label })}
        title={nt("widgets.remove", { name: label })}
        onClick={onRemove}
      >
        <Icon name="action.remove" size={12} />
      </button>
      {resizable && look === "badge" && (
        <div className="nt-widget-size-menu">
          <Menu>
            <MenuButton
              className="nt-widget-size-button"
              label={nt("widgets.size")}
              title={nt("widgets.size")}
              data-menu="widget-size"
              aria-haspopup="menu"
            >
              <Icon name="action.more" size={12} />
            </MenuButton>
            <MenuPopup label={nt("widgets.size")} className="acpmux-quick-menu" align="end">
              <MenuRadioGroup value={size} onValueChange={(value) => onResize(value as WidgetSize)}>
                {sizes.map((option) => (
                  <MenuRadioItem key={option} value={option} closeOnClick>
                    {sizeName(option)}
                  </MenuRadioItem>
                ))}
              </MenuRadioGroup>
            </MenuPopup>
          </Menu>
        </div>
      )}
      {resizable && look === "corner" && (
        <button
          type="button"
          className="nt-widget-corner"
          aria-label={`${nt("widgets.size")}: ${sizeName(next)}`}
          title={`${nt("widgets.size")}: ${sizeName(next)}`}
          onClick={() => onResize(next)}
        >
          <span aria-hidden="true" />
        </button>
      )}
      {resizable && look === "chips" && (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div className="nt-widget-chips" role="group" aria-label={nt("widgets.size")}>
          {sizes.map((option) => (
            <button
              key={option}
              type="button"
              className="nt-widget-chip"
              aria-pressed={option === size}
              onClick={() => option !== size && onResize(option)}
            >
              {sizeName(option)}
            </button>
          ))}
        </div>
      )}
      {meter && <output className="nt-widget-meter">{meter}</output>}
    </div>
  );
}
