// The category strip of a narrow Settings pane (layout.css, max-width 600px): the categories as one
// row that scrolls sideways. First-run audit row 13 (cmux-shots/first-run at 3:35): in the narrow
// right pane the strip showed "General, Updates, Personalization, Appea" and stopped, with nothing
// saying it scrolled. macOS hides the scrollbar and a mouse wheel turns only up and down, so the 25
// categories past the edge were out of reach for anyone without a trackpad. Three things make it
// read as a strip: the edges with categories past them fade (scrollEdges.ts marks them), a wheel
// turned up or down scrolls it sideways, and the shown category scrolls into view.
// A wide pane lays the list out as a column that does not scroll sideways, and none of this acts.

/** Room kept beside a category scrolled into view, so the fade does not dim it (px). */
export const STRIP_REVEAL_INSET = 24;

/** The strip scrolls sideways: its content is wider than its box. */
export function stripOverflows(node: HTMLElement): boolean {
  return node.scrollWidth - node.clientWidth > 1;
}

/** The strip's offset that shows `link` whole, `inset` px clear of each edge where it can; the
 * current offset when it already shows. Left-to-right offsets (0 at the strip's start). */
export function revealOffset(
  strip: { scrollLeft: number; clientWidth: number; scrollWidth: number },
  link: { left: number; width: number },
  inset = STRIP_REVEAL_INSET,
): number {
  const max = Math.max(0, strip.scrollWidth - strip.clientWidth);
  const start = strip.scrollLeft;
  const end = start + strip.clientWidth;
  let next = start;
  if (link.left - inset < start) next = link.left - inset;
  else if (link.left + link.width + inset > end) next = link.left + link.width + inset - strip.clientWidth;
  return Math.min(max, Math.max(0, next));
}

/** Scrolls the strip so `link` shows (a narrow pane only). */
export function revealInStrip(node: HTMLElement, link: HTMLElement): void {
  if (!stripOverflows(node)) return;
  const box = node.getBoundingClientRect();
  const own = link.getBoundingClientRect();
  const left = own.left - box.left + node.scrollLeft;
  const next = revealOffset(
    { scrollLeft: node.scrollLeft, clientWidth: node.clientWidth, scrollWidth: node.scrollWidth },
    { left, width: own.width },
  );
  if (Math.abs(next - node.scrollLeft) >= 1) node.scrollLeft = next;
}

/** A wheel turned up or down over the strip scrolls it sideways while it overflows; a sideways
 * wheel or trackpad swipe stays the browser's. Returns what stops following. */
export function followStripWheel(node: HTMLElement): () => void {
  const wheel = (event: WheelEvent) => {
    if (event.ctrlKey || !stripOverflows(node)) return;
    if (Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return;
    // Lines and pages (a mouse with line steps) in px, as the browser scrolls them.
    const scale = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? node.clientWidth : 1;
    const before = node.scrollLeft;
    node.scrollLeft = before + event.deltaY * scale;
    // At an end the wheel goes on to the page (it scrolls the content as before).
    if (node.scrollLeft !== before) event.preventDefault();
  };
  node.addEventListener("wheel", wheel, { passive: false });
  return () => node.removeEventListener("wheel", wheel);
}
