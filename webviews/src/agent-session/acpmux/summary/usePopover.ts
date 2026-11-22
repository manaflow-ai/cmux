// A popover button's behavior: opening moves focus to the popover's first control, Escape
// closes it and returns focus to the button, and a press outside both closes it.
import { useEffect, useLayoutEffect, useRef, useState } from "react";

export function usePopover() {
  const [open, setOpen] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  const popover = useRef<HTMLDialogElement>(null);
  useLayoutEffect(() => {
    if (open) (popover.current?.querySelector<HTMLElement>("a[href], button") ?? popover.current)?.focus();
  }, [open]);
  useEffect(() => {
    if (!open) return;
    const away = (event: Event) => {
      const target = event.target as Node;
      if (!popover.current?.contains(target) && !button.current?.contains(target)) setOpen(false);
    };
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      event.preventDefault();
      setOpen(false);
      button.current?.focus();
    };
    document.addEventListener("pointerdown", away, true);
    document.addEventListener("keydown", escape);
    return () => {
      document.removeEventListener("pointerdown", away, true);
      document.removeEventListener("keydown", escape);
    };
  }, [open]);
  return { open, setOpen, button, popover, toggle: () => setOpen((current) => !current) };
}
