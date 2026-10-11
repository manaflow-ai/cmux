import { useLayoutEffect, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { cx } from "./cx";

/** An action in the standalone context menu. */
export interface ContextMenuItem {
  id: string;
  label: ReactNode;
  ariaLabel?: string;
  disabled?: boolean;
  destructive?: boolean;
  separatorBefore?: boolean;
  onSelect(): void;
}

export interface ContextMenuProps {
  items: readonly ContextMenuItem[];
  children: ReactNode;
  className?: string;
  /**
   * "menu": a right-click over selected text opens this menu too (the surface offers its own
   * selected-text items, such as Cut and Copy). By default a selection keeps the host's menu.
   */
  selection?: "menu";
  /** Called as the menu opens, before it renders, so items can read what was under the pointer. */
  onOpen?(): void;
  /** Targets (a CSS selector) that keep the host's own menu, such as a text field's Cut, Copy and Paste. */
  ignore?: string;
}

/**
 * A point-anchored context menu for surfaces that do not use the shared Menu trigger.
 * It owns only the context-menu gesture; regular menus and selects should use `Menu`/`Select`.
 * A right-click over selected text keeps the host's native menu (Copy), unless `selection="menu"`.
 * The menu renders at the document root: a fixed popup inside an ancestor with a transform (or a
 * transform animation, such as a settings category's enter animation) is placed relative to that
 * ancestor, not the viewport, so it opened away from the pointer (cx-dmnf). Escape returns focus to
 * the invoking control when it has one.
 */
export function ContextMenu({ items, children, className, selection, onOpen, ignore }: ContextMenuProps) {
  const [point, setPoint] = useState<{ x: number; y: number } | null>(null);
  const [menuPosition, setMenuPosition] = useState<{ left: number; top: number } | null>(null);
  const [active, setActive] = useState(0);
  const returnFocus = useRef<HTMLElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);
  const enabled = items.filter((item) => !item.disabled);
  const close = (restoreFocus = false) => {
    setPoint(null);
    const target = returnFocus.current;
    returnFocus.current = null;
    if (restoreFocus && target?.isConnected) target.focus({ preventScroll: true });
  };
  const run = (item: ContextMenuItem | undefined) => {
    if (!item || item.disabled) return;
    close();
    item.onSelect();
  };
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>, restoreFocus = false) => {
    if (event.key === "Escape") {
      event.preventDefault();
      close(restoreFocus);
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      if (enabled.length === 0) return;
      event.preventDefault();
      setActive((index) => (index + (event.key === "ArrowDown" ? 1 : -1) + enabled.length) % enabled.length);
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      run(enabled[active]);
    }
  };
  useLayoutEffect(() => {
    if (!point) {
      setMenuPosition(null);
      return;
    }
    const positionMenu = () => {
      const menu = menuRef.current;
      if (!menu) return;
      const margin = 4;
      const rect = menu.getBoundingClientRect();
      // jsdom and the first layout pass can report zero dimensions. The CSS min-width keeps
      // the fallback conservative, while a real layout uses the measured popup size.
      const width = rect.width || 180;
      const height = rect.height;
      const maxLeft = Math.max(margin, window.innerWidth - width - margin);
      const maxTop = Math.max(margin, window.innerHeight - height - margin);
      const left = Math.max(margin, Math.min(point.x, maxLeft));
      const hasRoomBelow = height === 0 || point.y + height + margin <= window.innerHeight;
      const preferredTop = hasRoomBelow ? point.y : point.y - height;
      const top = Math.max(margin, Math.min(preferredTop, maxTop));
      setMenuPosition((current) => (current?.left === left && current.top === top ? current : { left, top }));
    };
    positionMenu();
    window.addEventListener("resize", positionMenu);
    return () => window.removeEventListener("resize", positionMenu);
  }, [point]);
  return (
    <div
      className={cx("ui-context-menu-host", className)}
      onContextMenu={(event) => {
        if (selection !== "menu" && window.getSelection()?.isCollapsed === false) return;
        if (ignore && event.target instanceof Element && event.target.closest(ignore)) return;
        event.preventDefault();
        onOpen?.();
        setActive(0);
        setMenuPosition(null);
        const target = event.target instanceof Element ? event.target : null;
        returnFocus.current =
          target?.closest<HTMLElement>("button, a[href], input, select, textarea, [tabindex]:not([tabindex='-1'])") ??
          null;
        setPoint({ x: event.clientX, y: event.clientY });
      }}
    >
      {children}
      {point
        ? createPortal(
            // Placement is inline, not only in ui.css: a host that does not load ui.css (the agent
            // pane) still opens the menu at the pointer above the page (cx-j4sd).
            <div
              className="ui-context-menu-backdrop"
              style={{ position: "fixed", inset: 0, zIndex: "var(--layer-dropdown)" }}
              onPointerDown={() => close()}
            >
              <div
                // Takes focus when it opens, so Up/Down/Return work.
                ref={(node) => {
                  menuRef.current = node;
                  node?.focus();
                }}
                className="ui-popup ui-context-menu"
                role="menu"
                data-focus-ring="rows"
                tabIndex={-1}
                style={{
                  position: "fixed",
                  minWidth: 180,
                  left: `${menuPosition?.left ?? point.x}px`,
                  top: `${menuPosition?.top ?? Math.max(4, point.y)}px`,
                }}
                onPointerDown={(event) => event.stopPropagation()}
                onKeyDown={(event) => {
                  if (event.key === "Escape") {
                    onKeyDown(event, true);
                    return;
                  }
                  onKeyDown(event);
                }}
              >
                {items.map((item) => (
                  <div key={item.id} role="none">
                    {item.separatorBefore ? <hr className="ui-separator" /> : null}
                    <button
                      type="button"
                      role="menuitem"
                      className={cx("ui-menu-item", item.destructive && "ui-menu-item-destructive")}
                      disabled={item.disabled}
                      aria-label={item.ariaLabel ?? (typeof item.label === "string" ? item.label : undefined)}
                      onPointerEnter={() => !item.disabled && setActive(Math.max(0, enabled.indexOf(item)))}
                      data-highlighted={enabled[active] === item ? "" : undefined}
                      onClick={() => run(item)}
                    >
                      {item.label}
                    </button>
                  </div>
                ))}
              </div>
            </div>,
            document.body,
          )
        : null}
    </div>
  );
}
