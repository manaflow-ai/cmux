import { useEffect, useRef } from "react";

/// While a popover that is not a ui/Popover is open, Escape anywhere in the page closes it, not only
/// while its own control has the focus (the Effort popover: a click on its title takes the focus off
/// its slider). The listener is on the document in the bubble phase: a control that handles Escape
/// itself (the slider) stops the event first, and an Escape that something else in the page used
/// (`defaultPrevented`) is left alone, as is one inside `ignore` (a selector: the popover's own menus,
/// which close themselves first).
export function useEscapeCloses(open: boolean, close: () => void, ignore?: string): void {
  const latest = useRef(close);
  latest.current = close;
  useEffect(() => {
    if (!open) return;
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented || event.isComposing) return;
      if (ignore && event.target instanceof Element && event.target.closest(ignore)) return;
      event.preventDefault();
      latest.current();
    };
    document.addEventListener("keydown", escape);
    return () => document.removeEventListener("keydown", escape);
  }, [open, ignore]);
}
