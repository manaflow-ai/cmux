import { focusWithRing } from "./focusWithRing";

/// Escape closes a menu or popover back onto the control that opened it, however it opened. It comes
/// back with no focus ring: Escape is how a person cancels the ring (FOCUS-RING, focusModality.ts),
/// and the next Tab or arrow shows it again from there. A mouse press opens one without focusing its
/// control, and Base UI then returns focus to whatever had it before (the prompt); this runs after
/// that return, so a pick or a press elsewhere keeps Base UI's default.
export function focusAfterEscape(control: HTMLElement | null | undefined): void {
  if (!control) return;
  setTimeout(() => {
    if (control.isConnected && !control.closest("[inert]"))
      focusWithRing(control, { preventScroll: true, focusVisible: false });
  });
}
