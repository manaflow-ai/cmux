// Native toasts are window overlays. They must never reserve room in the page: the composer and
// transcript keep the same frame while a toast appears, moves or leaves (design/notifications.md
// rule 10). The host still calls this bridge for older panes; it is intentionally a compatibility
// no-op on the web side. Keeping the bridge avoids a native protocol change and lets split panes
// converge on the same overlay behavior.

/// Receives the host's legacy toast-room measurement. The measurement is ignored because a native
/// toast floats over the pane instead of changing the page's layout.
export function setToastRoom(px: number, doc: Document = document, ms = 0): void {
  void px;
  void ms;
  doc.documentElement.style.removeProperty("--cmux-toast-room");
}

/// Lets the host set the band: `globalThis.__cmuxToastRoom(px, ms)`.
export function installToastRoom(doc: Document = document): void {
  (globalThis as typeof globalThis & { __cmuxToastRoom?: (px: number, ms?: number) => void }).__cmuxToastRoom = (
    px,
    ms,
  ) => setToastRoom(Number(px), doc, Number(ms) || 0);
}
