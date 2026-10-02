// A menu button's behavior: it opens on its first item, arrows, Home and End move through the
// items, Enter or Space runs one, and Escape, Tab or a press elsewhere closes it. Escape returns
// focus to the button; the changes view closes on Escape too, so the menu's Escape stops there.
import type React from "react";
import { useEffect, useLayoutEffect, useRef, useState } from "react";

export function useMenuButton() {
  const [open, setOpen] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const close = (refocus: boolean) => {
    setOpen(false);
    if (refocus) button.current?.focus();
  };
  useLayoutEffect(() => {
    if (open) menu.current?.querySelector<HTMLElement>('[role="menuitem"]:not(:disabled)')?.focus();
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
  const onKeyDown = (event: React.KeyboardEvent) => {
    const all = [...(menu.current?.querySelectorAll<HTMLElement>('[role="menuitem"]:not(:disabled)') ?? [])];
    const at = all.indexOf(document.activeElement as HTMLElement);
    const focus = (index: number) => all[(index + all.length) % all.length]?.focus();
    if (event.key === "Escape") {
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
  /// Runs a picked item: the menu closes, and focus returns to the button once the item is
  /// done (a copy can fall back to a selection copy, which takes focus).
  const run = (item: () => unknown) => {
    close(false);
    void Promise.resolve(item()).finally(() => button.current?.focus());
  };
  // WebKit does not focus a clicked button, so closing from it puts focus there.
  const toggle = () => (open ? close(true) : setOpen(true));
  return { open, button, menu, onKeyDown, run, toggle };
}
