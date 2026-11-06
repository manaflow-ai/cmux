/// Whether every create-strip label fits beside its glyph in the room its item has. The items share
/// the strip's width equally (screen.css), so an item's room does not depend on whether its label
/// shows; a title's own text width (`scrollWidth`) is read even while it is hidden. False only once
/// the strip is laid out (a strip with no width yet fits).
export function createStripLabelsFit(strip: HTMLElement): boolean {
  const view = strip.ownerDocument.defaultView;
  for (const item of strip.querySelectorAll<HTMLElement>(".nt-create-strip-item")) {
    const title = item.querySelector<HTMLElement>(".nt-row-title");
    if (!title || !view || item.clientWidth === 0) continue;
    const style = view.getComputedStyle(item);
    const glyph = item.querySelector<HTMLElement>(".nt-row-glyph")?.offsetWidth ?? 0;
    const gap = Number.parseFloat(style.columnGap) || 0;
    const room =
      item.clientWidth - Number.parseFloat(style.paddingLeft) - Number.parseFloat(style.paddingRight) - glyph - gap;
    if (title.scrollWidth > room + 0.5) return false;
  }
  return true;
}

/// The strip's ref: its labels show only while all of them fit; otherwise the three actions go
/// icon-only together (`data-icons-only`), their names kept in `aria-label` and the tooltip, rather
/// than three ellipsized "Nouv…" (Leo's French 320px pane). Measured per language, so English keeps its
/// labels at widths where French needs icons. One ResizeObserver per mounted strip, stopped when it
/// unmounts or its titles change (a new ref); setting the attribute changes no item width, so a
/// resize never feeds itself.
export function fitCreateStrip(strip: HTMLElement | null): (() => void) | undefined {
  if (!strip) return undefined;
  const fit = () => {
    if (createStripLabelsFit(strip)) delete strip.dataset.iconsOnly;
    else strip.dataset.iconsOnly = "";
  };
  fit();
  const view = strip.ownerDocument.defaultView;
  if (!view?.ResizeObserver) return undefined;
  const observer = new view.ResizeObserver(fit);
  observer.observe(strip);
  // The web font can land after the first measure and change every label's width.
  void strip.ownerDocument.fonts?.ready.then(fit);
  return () => observer.disconnect();
}
