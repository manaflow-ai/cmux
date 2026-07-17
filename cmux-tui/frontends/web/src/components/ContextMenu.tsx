import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import type { ContextMenuPoint } from "../lib/contextMenu";

export interface ContextMenuItem {
  label: string;
  danger?: boolean;
  onSelect?(): void;
  children?: ContextMenuItem[];
  separator?: boolean;
}

interface ContextMenuProps {
  point: ContextMenuPoint;
  items: ContextMenuItem[];
  onClose(): void;
}

interface MenuPopoverProps {
  point: ContextMenuPoint;
  onClose(): void;
  children: ReactNode;
  className?: string;
  ariaLabel?: string;
}

export function MenuPopover({ point, onClose, children, className, ariaLabel }: MenuPopoverProps) {
  const menuRef = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState(point);

  useLayoutEffect(() => {
    const menu = menuRef.current;
    if (!menu) return;
    const rect = menu.getBoundingClientRect();
    setPosition({
      x: Math.max(8, Math.min(point.x, window.innerWidth - rect.width - 8)),
      y: Math.max(8, Math.min(point.y, window.innerHeight - rect.height - 8)),
    });
    menu.querySelector<HTMLButtonElement>('button[role="menuitem"]')?.focus();
  }, [point]);

  useEffect(() => {
    const closeOutside = (event: PointerEvent) => {
      if (!menuRef.current?.contains(event.target as Node)) onClose();
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    document.addEventListener("pointerdown", closeOutside, true);
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("pointerdown", closeOutside, true);
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, [onClose]);

  const moveFocus = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const active = document.activeElement as HTMLButtonElement;
    const activeMenu = active.closest<HTMLDivElement>('[role="menu"]') ?? event.currentTarget;
    const direct = activeMenu.querySelectorAll<HTMLButtonElement>(
      ':scope > .context-menu-items > .context-menu-entry > button[role="menuitem"]',
    );
    const buttons = [...(direct.length > 0
      ? direct
      : activeMenu.querySelectorAll<HTMLButtonElement>('button[role="menuitem"]'))];
    const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
    const offset = event.key === "ArrowDown" ? 1 : -1;
    buttons[(index + offset + buttons.length) % buttons.length]?.focus();
  };

  return createPortal(
    <div
      className={`context-menu${className ? ` ${className}` : ""}`}
      aria-label={ariaLabel}
      onKeyDown={moveFocus}
      ref={menuRef}
      role="menu"
      style={{ left: position.x, top: position.y }}
    >
      {children}
    </div>,
    document.body,
  );
}

export function ContextMenu({ point, items, onClose }: ContextMenuProps) {
  return (
    <MenuPopover point={point} onClose={onClose}>
      <MenuItems items={items} onClose={onClose} />
    </MenuPopover>
  );
}

function MenuItems({ items, onClose }: { items: ContextMenuItem[]; onClose(): void }) {
  return (
    <div className="context-menu-items">
      {items.map((item, index) => {
        if (item.separator) {
          return <div className="context-menu-separator" key={`separator-${index}`} role="separator" />;
        }
        const nested = item.children && item.children.length > 0;
        return (
          <div className="context-menu-entry" key={`${item.label}-${index}`}>
            <button
              aria-haspopup={nested ? "menu" : undefined}
              className={item.danger ? "danger" : undefined}
              onClick={(event) => {
                if (nested) {
                  event.currentTarget.parentElement
                    ?.querySelector<HTMLButtonElement>(".context-menu-submenu button")
                    ?.focus();
                  return;
                }
                onClose();
                item.onSelect?.();
              }}
              onKeyDown={(event) => {
                if (event.key === "ArrowRight" && nested) {
                  event.preventDefault();
                  event.currentTarget.parentElement
                    ?.querySelector<HTMLButtonElement>(".context-menu-submenu button")
                    ?.focus();
                } else if (event.key === "ArrowLeft") {
                  const submenu = event.currentTarget.closest<HTMLElement>(".context-menu-submenu");
                  const parentButton = submenu?.parentElement?.querySelector<HTMLButtonElement>(
                    ":scope > button",
                  );
                  if (parentButton) {
                    event.preventDefault();
                    parentButton.focus();
                  }
                }
              }}
              role="menuitem"
              type="button"
            >
              <span>{item.label}</span>
              {nested && <span className="context-menu-arrow" aria-hidden="true">›</span>}
            </button>
            {nested && (
              <div className="context-menu context-menu-submenu" role="menu">
                <MenuItems items={item.children!} onClose={onClose} />
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}
