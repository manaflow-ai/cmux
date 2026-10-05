// A changed file's More menu: Copy path, Open file in a tab,
// and Collapse file (Expand file when folded). It is a menu button: it opens on its first
// item, arrows move through the items, Enter or Space runs one, and Escape, Tab or a press
// elsewhere closes it.
import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { More } from "../changeIcons";
import { copyText } from "../conversation/clipboard";
import { useT } from "../i18n";

export function FileMenu({
  path,
  name,
  collapsed,
  onToggleCollapsed,
  onOpenInTab,
}: {
  path: string;
  name: string;
  collapsed: boolean;
  onToggleCollapsed: () => void;
  /// Absent for a file with nothing on disk to open, such as a deleted one.
  onOpenInTab?: () => void;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const close = (refocus: boolean) => {
    setOpen(false);
    if (refocus) button.current?.focus();
  };
  useLayoutEffect(() => {
    if (open) menu.current?.querySelector<HTMLElement>('[role="menuitem"]')?.focus();
  }, [open]);
  useEffect(() => {
    if (!open) return;
    const away = (event: Event) => {
      const target = event.target as Node;
      if (!menu.current?.contains(target) && !button.current?.contains(target)) setOpen(false);
    };
    document.addEventListener("pointerdown", away, true);
    return () => document.removeEventListener("pointerdown", away, true);
  }, [open]);
  const items = [
    // The copy can fall back to a selection copy, which takes focus; focus returns after it.
    { label: t("changes.copyPath"), run: () => copyText(path) },
    ...(onOpenInTab ? [{ label: t("changes.openInTab"), run: onOpenInTab }] : []),
    { label: collapsed ? t("changes.expandFile") : t("changes.collapseFile"), run: onToggleCollapsed },
  ];
  const onKeyDown = (event: React.KeyboardEvent) => {
    const all = [...(menu.current?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])];
    const at = all.indexOf(document.activeElement as HTMLElement);
    const focus = (index: number) => all[(index + all.length) % all.length]?.focus();
    if (event.key === "Escape") {
      // The changes view closes on Escape too; this one is the menu's.
      event.preventDefault();
      event.stopPropagation();
      close(true);
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      focus(at + (event.key === "ArrowDown" ? 1 : -1));
    } else if (event.key === "Home" || event.key === "End") {
      event.preventDefault();
      focus(event.key === "Home" ? 0 : all.length - 1);
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      all[at]?.click();
    } else if (event.key === "Tab") close(false);
  };
  return (
    <span className="acpmux-file-menu">
      <button
        ref={button}
        type="button"
        className="acpmux-fh-btn"
        aria-label={t("changes.moreActionsFor", { name })}
        aria-haspopup="menu"
        aria-expanded={open}
        title={t("changes.moreActions")}
        // WebKit does not focus a clicked button, so closing from it puts focus there.
        onClick={() => (open ? close(true) : setOpen(true))}
      >
        <More />
      </button>
      {open && (
        <div
          ref={menu}
          role="menu"
          tabIndex={-1}
          className="acpmux-file-menu-list"
          aria-label={t("changes.actionsFor", { name })}
          onKeyDown={onKeyDown}
        >
          {items.map((item) => (
            <button
              key={item.label}
              type="button"
              role="menuitem"
              tabIndex={-1}
              className="acpmux-file-menu-item"
              onClick={() => {
                close(false);
                void Promise.resolve(item.run()).finally(() => button.current?.focus());
              }}
            >
              {item.label}
            </button>
          ))}
        </div>
      )}
    </span>
  );
}
