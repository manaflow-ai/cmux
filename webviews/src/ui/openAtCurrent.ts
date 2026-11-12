// Pickers and menus open on their current value (Leo, 2026-11-12: "my selected theme vs when i open
// up the thing. shouldn't the opened thing be jumped already to the proper place?"). The row is
// centred in its scroller before the first paint, with no scroll animation.

/// Centres `row` in its nearest scrolling ancestor, stopping at `within`'s parent. Instant, even
/// where the scroller asks for smooth scrolling.
export function centreInScroller(row: HTMLElement | null, within: HTMLElement | null): void {
  if (!row || !within) return;
  let scroller: HTMLElement | null = row.parentElement;
  while (scroller && scroller !== within.parentElement) {
    const overflow = getComputedStyle(scroller).overflowY;
    if ((overflow === "auto" || overflow === "scroll") && scroller.scrollHeight > scroller.clientHeight) break;
    scroller = scroller === within ? null : scroller.parentElement;
  }
  if (!scroller || typeof scroller.scrollTo !== "function") return;
  const box = scroller.getBoundingClientRect();
  const at = row.getBoundingClientRect();
  const top = scroller.scrollTop + (at.top - box.top) - (scroller.clientHeight - at.height) / 2;
  scroller.scrollTo({ top: Math.max(0, top), behavior: "instant" });
}

/// A menu's checked radio or checkbox row, the menu's current value.
export function checkedMenuRow(popup: HTMLElement): HTMLElement | null {
  return popup.querySelector<HTMLElement>(
    ':scope [role="menuitemradio"][aria-checked="true"], :scope [role="menuitemradio"][data-checked]',
  );
}
