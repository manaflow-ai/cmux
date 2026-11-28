// Cmd-F on a page with its own search field (Settings, Keyboard Shortcuts, Passwords): the app's
// key dispatcher sends `focusSearch` (or `find`), and the page focuses and selects that field, so
// typing replaces the old query (the native search-field convention).

/** Focuses the search field `selector` names and selects its text. False when there is none. */
export function focusSearchField(doc: Document, selector: string): boolean {
  const input = doc.querySelector<HTMLInputElement>(selector);
  if (!input) return false;
  input.focus();
  input.select();
  return true;
}
