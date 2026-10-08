import { useEffect, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
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
}

/**
 * A point-anchored context menu for surfaces that do not use the shared Menu trigger.
 * It owns only the context-menu gesture; regular menus and selects should use `Menu`/`Select`.
 */
export function ContextMenu({ items, children, className }: ContextMenuProps) {
  const [point, setPoint] = useState<{ x: number; y: number } | null>(null);
  const [active, setActive] = useState(0);
  const menu = useRef<HTMLDivElement>(null);
  const enabled = items.filter((item) => !item.disabled);
  const close = () => setPoint(null);
  const run = (item: ContextMenuItem | undefined) => {
    if (!item || item.disabled) return;
    close();
    item.onSelect();
  };
  useEffect(() => {
    if (point) menu.current?.focus();
  }, [point]);
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key === "Escape") {
      event.preventDefault();
      close();
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      if (enabled.length === 0) return;
      event.preventDefault();
      setActive((index) => (index + (event.key === "ArrowDown" ? 1 : -1) + enabled.length) % enabled.length);
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      run(enabled[active]);
    }
  };
  return (
    <div
      className={cx("ui-context-menu-host", className)}
      onContextMenu={(event) => {
        event.preventDefault();
        setActive(0);
        setPoint({ x: event.clientX, y: event.clientY });
      }}
    >
      {children}
      {point ? (
        <div className="ui-context-menu-backdrop" onPointerDown={close}>
          <div
            ref={menu}
            className="ui-popup ui-context-menu"
            role="menu"
            tabIndex={-1}
            style={{ left: Math.max(4, Math.min(point.x, window.innerWidth - 244)), top: Math.max(4, point.y) }}
            onPointerDown={(event) => event.stopPropagation()}
            onKeyDown={onKeyDown}
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
        </div>
      ) : null}
    </div>
  );
}
