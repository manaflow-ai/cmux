import { useEffect, useRef } from "react";

/// While a popover that is not a ui/Popover is open, Escape anywhere in the page closes it, not only
/// while its own control has the focus (the Effort popover: a click on its title takes the focus off
/// its slider). The listener is on the document in the bubble phase: a control that handles Escape
/// itself (the slider) stops the event first, and an Escape that something else in the page used
/// (`defaultPrevented`) is left alone.
export function useEscapeCloses(open: boolean, close: () => void): void {
  const latest = useRef(close);
  latest.current = close;
  useEffect(() => {
    if (!open) return;
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented || event.isComposing) return;
      event.preventDefault();
      latest.current();
    };
    document.addEventListener("keydown", escape);
    return () => document.removeEventListener("keydown", escape);
  }, [open]);
}
