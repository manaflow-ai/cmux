// A small anchored menu for page context menus and header menus. It draws in the page (engine
// neutral: WebKit, CEF and a plain browser), closes on a click outside (a transparent backdrop, no
// document listeners) and on Escape, and takes focus so Up/Down/Return work. No Cmd/Ctrl chords.
import { useState, type KeyboardEvent } from "react";

export interface PageMenuItem {
  id: string;
  label: string;
  destructive?: boolean;
  separatorBefore?: boolean;
  disabled?: boolean;
  run: () => void;
}

export interface PageMenuProps {
  x: number;
  y: number;
  items: PageMenuItem[];
  onClose: () => void;
}

export function PageMenu({ x, y, items, onClose }: PageMenuProps) {
  const enabled = items.filter((item) => !item.disabled);
  const [active, setActive] = useState(0);
  const run = (item: PageMenuItem | undefined) => {
    if (!item || item.disabled) return;
    onClose();
    item.run();
  };
  const onKeyDown = (event: KeyboardEvent) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.key === "Escape") onClose();
    else if (event.key === "ArrowDown") setActive((index) => Math.min(enabled.length - 1, index + 1));
    else if (event.key === "ArrowUp") setActive((index) => Math.max(0, index - 1));
    else if (event.key === "Enter" || event.key === " ") run(enabled[active]);
    else return;
    event.preventDefault();
    event.stopPropagation();
  };
  // Keep the menu inside the viewport.
  const left = Math.max(4, Math.min(x, window.innerWidth - 240));
  const top = Math.max(4, Math.min(y, window.innerHeight - (items.length * 24 + 12)));
  return (
    <div
      className="page-menu-backdrop"
      onPointerDown={onClose}
      onContextMenu={(event) => (event.preventDefault(), onClose())}
    >
      <div
        className="page-menu"
        role="menu"
        tabIndex={-1}
        style={{ left, top }}
        ref={(node) => node?.focus()}
        onKeyDown={onKeyDown}
        onPointerDown={(event) => event.stopPropagation()}
      >
        {items.map((item) => (
          <div key={item.id} role="none">
            {item.separatorBefore && <hr className="page-menu-separator" />}
            <button
              type="button"
              role="menuitem"
              className={`page-menu-item${item.destructive ? " destructive" : ""}${enabled[active] === item ? " active" : ""}`}
              disabled={item.disabled}
              onPointerEnter={() => setActive(Math.max(0, enabled.indexOf(item)))}
              onClick={() => run(item)}
            >
              {item.label}
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}
