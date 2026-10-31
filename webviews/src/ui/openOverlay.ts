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

/** Whether `element` is drawn where the person can see it: not hidden (`hidden`, `inert` or
    `aria-hidden` on it or an ancestor, `display: none`, `visibility: hidden`) and with a box. A
    surface kept in the page while closed (the pages' one title tooltip, ui/titleTooltips.ts, stays
    in the body with `hidden`) is not open. */
export function isRendered(element: Element): boolean {
  if (element.closest("[hidden], [inert], [aria-hidden='true']")) return false;
  const view = element.ownerDocument.defaultView;
  const style = view?.getComputedStyle(element);
  if (style && (style.display === "none" || style.visibility === "hidden")) return false;
  const box = element.getBoundingClientRect();
  return box.width > 0 && box.height > 0;
}

/** Whether an overlay is open in `doc`: one drawn on screen (``isRendered``), leaving out one that is
    closing and any inside an element `ignore` matches. */
export function openOverlay(doc: Document, ignore?: string): boolean {
  for (const element of doc.querySelectorAll(OPEN_OVERLAY_SELECTOR)) {
    if (element.closest("[data-ending-style]")) continue;
    if (ignore && element.closest(ignore)) continue;
    if (isRendered(element)) return true;
  }
  return false;
}
