import { focusWithRing } from "./focusWithRing";

/// Escape closes a menu or popover back onto the control that opened it, with that control's focus
/// ring, however it opened. A mouse press opens one without focusing its control, and Base UI then
/// returns focus to whatever had it before (the prompt); this runs after that return, so a pick or a
/// press elsewhere keeps Base UI's default.
export function focusAfterEscape(control: HTMLElement | null | undefined): void {
  if (!control) return;
  setTimeout(() => {
    if (control.isConnected && !control.closest("[inert]"))
      focusWithRing(control, { preventScroll: true, focusVisible: true });
  });
}
