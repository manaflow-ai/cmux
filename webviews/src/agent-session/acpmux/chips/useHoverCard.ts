// A hover card's open and close (ui/hoverIntent.ts): it opens after the card dwell on hover, at
// once on keyboard focus, and closes after a short grace unless the pointer or the focus moved
// into the card. The link chips' preview card and the pull request bars share it.
import { useEffect, useRef, useState } from "react";
import { HOVER_INTENT } from "../../../ui/hoverIntent";

export function useHoverCard() {
  const [open, setOpen] = useState(false);
  const inCard = useRef(false);
  const openTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const closeTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const clearTimers = () => {
    if (openTimer.current !== undefined) clearTimeout(openTimer.current);
    if (closeTimer.current !== undefined) clearTimeout(closeTimer.current);
    openTimer.current = undefined;
    closeTimer.current = undefined;
  };
  const show = (immediate = false) => {
    clearTimers();
    if (immediate) setOpen(true);
    else openTimer.current = setTimeout(() => setOpen(true), HOVER_INTENT.cardDwell);
  };
  const hide = () => {
    clearTimers();
    closeTimer.current = setTimeout(() => {
      if (!inCard.current) setOpen(false);
    }, HOVER_INTENT.cardGrace);
  };
  useEffect(() => () => clearTimers(), []);
  return {
    open,
    /// For the element the card describes.
    trigger: {
      onPointerEnter: () => show(),
      onPointerLeave: () => hide(),
      onFocus: () => show(true),
      onBlur: () => hide(),
    },
    /// For an interactive card's content: the pointer or the focus inside keeps it open.
    card: {
      onPointerEnter: () => {
        clearTimers();
        inCard.current = true;
      },
      onPointerLeave: () => {
        inCard.current = false;
        hide();
      },
      onFocusCapture: () => {
        clearTimers();
        inCard.current = true;
        setOpen(true);
      },
      onBlurCapture: () => {
        inCard.current = false;
        hide();
      },
    },
  };
}
