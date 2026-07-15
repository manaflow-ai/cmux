import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import type { ContextMenuPoint } from "../lib/contextMenu";

export interface ContextMenuItem {
  label: string;
  danger?: boolean;
  onSelect(): void;
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
    const buttons = [...event.currentTarget.querySelectorAll<HTMLButtonElement>('button[role="menuitem"]')];
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
      {items.map((item) => (
        <button
          className={item.danger ? "danger" : undefined}
          key={item.label}
          onClick={() => {
            onClose();
            item.onSelect();
          }}
          role="menuitem"
          type="button"
        >
          {item.label}
        </button>
      ))}
    </MenuPopover>
  );
}
