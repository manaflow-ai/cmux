import {
  createContext,
  useContext,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
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

const MenuLayoutContext = createContext("root");

function focusMenuItem(item: HTMLButtonElement | null | undefined) {
  if (!item) return;
  item.focus({ preventScroll: true });
  item.scrollIntoView?.({ block: "nearest", inline: "nearest" });
}

export function MenuPopover({ point, onClose, children, className, ariaLabel }: MenuPopoverProps) {
  const menuRef = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState(point);
  const [layoutRevision, setLayoutRevision] = useState(0);

  useLayoutEffect(() => {
    const positionMenu = () => {
      const menu = menuRef.current;
      if (!menu) return;
      const rect = menu.getBoundingClientRect();
      setPosition({
        x: Math.max(8, Math.min(point.x, window.innerWidth - rect.width - 8)),
        y: Math.max(8, Math.min(point.y, window.innerHeight - rect.height - 8)),
      });
      setLayoutRevision((revision) => revision + 1);
    };
    positionMenu();
    const viewport = window.visualViewport;
    window.addEventListener("resize", positionMenu);
    viewport?.addEventListener("resize", positionMenu);
    viewport?.addEventListener("scroll", positionMenu);
    const menu = menuRef.current;
    focusMenuItem(menu?.querySelector<HTMLButtonElement>('button[role="menuitem"]'));
    return () => {
      window.removeEventListener("resize", positionMenu);
      viewport?.removeEventListener("resize", positionMenu);
      viewport?.removeEventListener("scroll", positionMenu);
    };
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
    focusMenuItem(buttons[(index + offset + buttons.length) % buttons.length]);
  };

  return createPortal(
    <MenuLayoutContext.Provider value={`${position.x}:${position.y}:${layoutRevision}`}>
      <div
        className={`context-menu${className ? ` ${className}` : ""}`}
        aria-label={ariaLabel}
        onKeyDown={moveFocus}
        onScrollCapture={() => setLayoutRevision((revision) => revision + 1)}
        ref={menuRef}
        role="menu"
        style={{ left: position.x, top: position.y }}
      >
        {children}
      </div>
    </MenuLayoutContext.Provider>,
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
                  focusMenuItem(event.currentTarget.parentElement
                    ?.querySelector<HTMLButtonElement>(".context-menu-submenu button"));
                  return;
                }
                onClose();
                item.onSelect?.();
              }}
              onKeyDown={(event) => {
                if (event.key === "ArrowRight" && nested) {
                  event.preventDefault();
                  focusMenuItem(event.currentTarget.parentElement
                    ?.querySelector<HTMLButtonElement>(".context-menu-submenu button"));
                } else if (event.key === "ArrowLeft") {
                  const submenu = event.currentTarget.closest<HTMLElement>(".context-menu-submenu");
                  const parentButton = submenu?.parentElement?.querySelector<HTMLButtonElement>(
                    ":scope > button",
                  );
                  if (parentButton) {
                    event.preventDefault();
                    focusMenuItem(parentButton);
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
              <Submenu items={item.children!} onClose={onClose} />
            )}
          </div>
        );
      })}
    </div>
  );
}

function Submenu({ items, onClose }: { items: ContextMenuItem[]; onClose(): void }) {
  const submenuRef = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState<{ left: number; top: number }>();
  const parentLayout = useContext(MenuLayoutContext);

  useLayoutEffect(() => {
    const submenu = submenuRef.current;
    const entry = submenu?.parentElement;
    if (!submenu || !entry) return;

    const margin = 8;
    const overlap = 2;
    const verticalOffset = 4;
    const submenuRect = submenu.getBoundingClientRect();
    const entryRect = entry.getBoundingClientRect();
    const maxX = Math.max(margin, window.innerWidth - submenuRect.width - margin);
    const maxY = Math.max(margin, window.innerHeight - submenuRect.height - margin);
    const opensLeft = entryRect.right + submenuRect.width - overlap > window.innerWidth - margin;
    const x = Math.max(
      margin,
      Math.min(opensLeft ? entryRect.left - submenuRect.width + overlap : entryRect.right - overlap, maxX),
    );
    const y = Math.max(margin, Math.min(entryRect.top - verticalOffset, maxY));
    const next = { left: x, top: y };
    setPosition((current) => current?.left === next.left && current.top === next.top ? current : next);
  }, [items, parentLayout]);

  return (
    <MenuLayoutContext.Provider
      value={`${parentLayout}/${position?.left ?? "pending"}:${position?.top ?? "pending"}`}
    >
      <div
        className="context-menu context-menu-submenu"
        ref={submenuRef}
        role="menu"
        style={position}
      >
        <MenuItems items={items} onClose={onClose} />
      </div>
    </MenuLayoutContext.Provider>
  );
}
