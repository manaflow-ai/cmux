// Pickers and menus open on their current value (Leo, 2026-11-12: "my selected theme vs when i open
// up the thing. shouldn't the opened thing be jumped already to the proper place?"). The row is
// centred in its scroller once per open, only that scroller moving.

/// Centres `row` in the nearest scroller between it and `within` (inclusive) when it is not already
/// wholly in view. Only that scroller moves, never the page behind the popup (`scrollIntoView`
/// would scroll every ancestor). A popup laid out after this commit has no height yet: try again on
/// the next frames.
export function centreInScroller(row: HTMLElement | null, within: HTMLElement | null, framesLeft = 3): void {
  if (!row || !within) return;
  let scroller: HTMLElement | null = row.parentElement;
  while (scroller && scroller !== within && scroller.scrollHeight <= scroller.clientHeight) {
    scroller = scroller.parentElement;
  }
  if (!scroller) return;
  if (scroller.clientHeight === 0) {
    if (framesLeft > 0) requestAnimationFrame(() => centreInScroller(row, within, framesLeft - 1));
    return;
  }
  const view = scroller.getBoundingClientRect();
  const box = row.getBoundingClientRect();
  if (box.top >= view.top && box.bottom <= view.bottom) return;
  scroller.scrollTop += box.top - view.top - (scroller.clientHeight - box.height) / 2;
}

/// A menu's checked radio or checkbox row, the menu's current value.
export function checkedMenuRow(popup: HTMLElement): HTMLElement | null {
  return popup.querySelector<HTMLElement>(
    ':scope [role="menuitemradio"][aria-checked="true"], :scope [role="menuitemradio"][data-checked]',
  );
}
