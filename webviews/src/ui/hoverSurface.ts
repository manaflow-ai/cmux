// ONE HOVER SURFACE AT A TIME (Leo, 2026-11-22: "the humongous bullshit fucking terrible multiple
// styles for hover previews"). A "Subagent disconnected" row showed two hovers for one pointer: the
// title tooltip of its sentence (ui/titleTooltips.ts) and the hover card of the subagent's chip inside
// it (ui/Tooltip.tsx). Every hover surface on a page (a Base UI tooltip or hover card, an
// AnchoredCard, a title tooltip) says here when it opens, and the title tooltip yields to any other:
// it hides when one opens and does not show while one is open. The newest hover wins.

/** The event a hover surface sends on its document when it opens; `detail` is its element. */
export const HOVER_SURFACE_OPEN = "cmux:hover-surface-open";

/** Every hover surface the page draws: tooltips, hover cards and toolbar hints. */
export const HOVER_SURFACE_SELECTOR = ".ui-tooltip, .ui-title-tooltip, .ui-hint";

/** Tells the page that `surface` opened, so no other hover surface stays beside it. */
export function announceHoverSurface(surface: Element): void {
  const doc = surface.ownerDocument;
  const Event = doc.defaultView?.CustomEvent ?? CustomEvent;
  doc.dispatchEvent(new Event(HOVER_SURFACE_OPEN, { detail: surface }));
}

/** Calls `onOpen` with each hover surface that opens on `doc`; returns the unsubscribe. */
export function onHoverSurfaceOpen(doc: Document, onOpen: (surface: Element) => void): () => void {
  const listener = (event: Event) => {
    const surface = (event as CustomEvent<unknown>).detail;
    if (surface instanceof (doc.defaultView?.Element ?? Element)) onOpen(surface as Element);
  };
  doc.addEventListener(HOVER_SURFACE_OPEN, listener);
  return () => doc.removeEventListener(HOVER_SURFACE_OPEN, listener);
}

/** A hover surface other than `except` that is open on `doc` now (not hidden or closing). */
export function otherHoverSurfaceOpen(doc: Document, except: Element): boolean {
  for (const surface of doc.querySelectorAll(HOVER_SURFACE_SELECTOR)) {
    if (surface === except || surface.contains(except) || except.contains(surface)) continue;
    if ((surface as HTMLElement).hidden || surface.hasAttribute("data-ending-style")) continue;
    // A gallery's or a document's static example is not open on the page.
    if (!surface.isConnected || surface.closest("[data-hover-surface-static]")) continue;
    // Mounted but not drawn (display: none, an empty box) covers nothing.
    const box = surface.getBoundingClientRect();
    if (box.width === 0 && box.height === 0) continue;
    return true;
  }
  return false;
}
