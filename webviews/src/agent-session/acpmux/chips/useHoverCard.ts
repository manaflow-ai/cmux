// A hover card's open and close (ui/hoverIntent.ts): it opens after the card dwell on hover, at
// once on keyboard focus, and closes after a short grace unless the pointer or the keyboard focus
// moved into the card, or a menu the card opened (Open in) is still open. Every link's card shares
// it (LinkHoverCard.tsx): reply links, pull request chips and the pull request bars.
import { useCallback, useEffect, useRef, useState, type FocusEvent } from "react";
import { HOVER_INTENT } from "../../../ui/hoverIntent";

export type HoverCard = ReturnType<typeof useHoverCard>;

/// `dwell`: the pointer rest before it opens (the hover-card dwell; an icon-only control whose
/// card replaces its tooltip waits the tooltip delay).
export function useHoverCard(dwell: number = HOVER_INTENT.cardDwell) {
  const [open, setOpen] = useState(false);
  const inCard = useRef(false);
  /// The card's Open in menu is open: the card stays until it closes.
  const menuOpen = useRef(false);
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
    else openTimer.current = setTimeout(() => setOpen(true), dwell);
  };
  const hide = () => {
    clearTimers();
    closeTimer.current = setTimeout(() => {
      if (!inCard.current && !menuOpen.current) setOpen(false);
    }, HOVER_INTENT.cardGrace);
  };
  // Stable across renders, so a caller's Escape listener can depend on it.
  const dismiss = useCallback(() => {
    if (openTimer.current !== undefined) clearTimeout(openTimer.current);
    if (closeTimer.current !== undefined) clearTimeout(closeTimer.current);
    openTimer.current = undefined;
    closeTimer.current = undefined;
    inCard.current = false;
    setOpen(false);
  }, []);
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
    /// For the card's content: the pointer or the keyboard focus inside keeps it open.
    card: {
      onPointerEnter: () => {
        clearTimers();
        inCard.current = true;
      },
      onPointerLeave: () => {
        inCard.current = false;
        hide();
      },
      onFocusCapture: (event: FocusEvent<HTMLElement>) => {
        // Keyboard focus keeps the card. A pointer pick in Open in puts focus back on its trigger
        // with no ring (Menu's focusAfterClose); that alone doesn't pin the card once the pointer
        // has left it.
        if (!(event.target as Element).matches(":focus-visible") && !event.currentTarget.matches(":hover")) return;
        clearTimers();
        inCard.current = true;
        setOpen(true);
      },
      onBlurCapture: () => {
        inCard.current = false;
        hide();
      },
    },
    /// Closes the card now (Escape), however it opened; the next hover or focus opens it again.
    dismiss,
    /// The card's Open in menu opened or closed.
    menuChanged: (next: boolean) => {
      menuOpen.current = next;
      if (next) clearTimers();
      else hide();
    },
  };
}
