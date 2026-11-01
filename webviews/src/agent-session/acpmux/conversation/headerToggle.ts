// A collapsible's whole header line is its toggle, edge to edge: its padding, its icon, its words,
// its counts and the space between them, not only the strip its button or title covers (Leo,
// 2026-10-31, on the edits card: "this thing i can't click the whole thing to expand/collapse only
// on the middle strip it's weird and bad"). The header's own button (the chevron, or the line's
// toggle) stays the keyboard and screen reader control; this is the pointer's wider target.
//
// A click on a real control inside the header (View changes, Undo, a sender chip, Reply, a menu)
// is that control's own, and a press that ended a text selection in the header selects, so neither
// toggles. The header carries `data-header-toggle` so the transcript holds it in place while its
// body folds (foldAnchor.ts), as it does for a toggle button.
import type { MouseEvent } from "react";

/// The controls inside a header that keep their own click.
/// `data-own-click` marks a part that keeps the click without being a control: a received message's
/// sender, which sits before the line's toggle and outside it (Leo, 2026-10-29: "make the left side
/// identifier like it was before and you can click it to go to that session").
export const HEADER_INNER_CONTROL =
  'button, a[href], [role="button"], [role="link"], [role="menuitem"], summary, input, textarea, select, label, [contenteditable="true"], [data-own-click]';

/// The header's attribute: foldAnchor.ts holds a click anywhere on it.
export const HEADER_TOGGLE_ATTRIBUTE = "data-header-toggle";

/// Whether a click at `target` on `header` is the header's toggle: inside it (not a portal's content
/// bubbling through React), not on a control of its own, and not the end of a selection drag.
export function togglesHeader(header: Element, target: EventTarget | null): boolean {
  const element = target && typeof (target as Element).closest === "function" ? (target as Element) : null;
  if (!element || !header.contains(element)) return false;
  const control = element.closest(HEADER_INNER_CONTROL);
  if (control && control !== header && header.contains(control)) return false;
  const selection = header.ownerDocument.defaultView?.getSelection();
  if (selection && !selection.isCollapsed && selection.anchorNode && header.contains(selection.anchorNode))
    return false;
  return true;
}

/// The header's click handler: `toggle` for a primary click anywhere on it but its own controls.
export function headerToggleClick(toggle: () => void) {
  return (event: MouseEvent<HTMLElement>) => {
    if (event.defaultPrevented || event.button !== 0) return;
    if (togglesHeader(event.currentTarget, event.target)) toggle();
  };
}
