// Whether a menu, popover, dialog, picker, hover card or tooltip is open in a page: every surface
// the shared primitives draw (ui/Popover, Menu, Select, Combobox, the interactive AnchoredCard and
// Tooltip, ui/Tooltip.tsx) and any ARIA popup. A closing one (Base UI's data-ending-style fade) no
// longer counts. Feature tips use it so a tip never opens over one (design/feature-tips.md).
export const OPEN_OVERLAY_SELECTOR = [
  "dialog[open]",
  '[role="dialog"]',
  '[role="alertdialog"]',
  '[aria-modal="true"]',
  '[role="menu"]',
  '[role="listbox"]',
  '[role="tooltip"]',
  ".ui-popup",
  ".ui-tooltip",
  ".ui-card",
  ".acpmux-menu",
].join(", ");

/** Whether an overlay is open in `doc`, leaving out any inside an element `ignore` matches. */
export function openOverlay(doc: Document, ignore?: string): boolean {
  for (const element of doc.querySelectorAll(OPEN_OVERLAY_SELECTOR)) {
    if (element.closest("[data-ending-style]")) continue;
    if (ignore && element.closest(ignore)) continue;
    return true;
  }
  return false;
}
