// A box the page sends the App, where the App sees it: on the pinch-zoomed screen, not in the page's
// layout (Leo, 2026-11-12: "when you e.g. zoom in to the ui with the trackpad it gives this super
// strange kinda ghost glass in the back?"). A trackpad pinch in a Chromium page zooms its visual
// viewport only: the content is scaled and panned on screen, but `getBoundingClientRect` and the
// layout stay as they were. The App's glass and cut-outs, placed from those boxes, stayed at the
// unzoomed spot behind the zoomed content. Each box is mapped through `visualViewport` (its offset
// into the layout and its scale) before it goes, so the App's view of it moves with the content.
// With no pinch (scale 1, offset 0) the box is unchanged.

/** The edges of a box in the page's viewport, CSS px. */
export type ViewportEdges = { left: number; top: number; right: number; bottom: number };

/** The visual viewport's scale, 1 with no pinch or none to read. */
export function visualViewportScale(view: Window | null | undefined): number {
  const scale = view?.visualViewport?.scale ?? 1;
  return Number.isFinite(scale) && scale > 0 ? scale : 1;
}

/** `box` (layout viewport CSS px) where it shows on the pinch-zoomed screen, in unzoomed CSS px. */
export function onVisualViewport<T extends ViewportEdges>(box: T, view: Window | null | undefined): T {
  const visual = view?.visualViewport;
  const scale = visualViewportScale(view);
  const x = visual?.offsetLeft ?? 0;
  const y = visual?.offsetTop ?? 0;
  if (scale === 1 && x === 0 && y === 0) return box;
  return {
    ...box,
    left: (box.left - x) * scale,
    top: (box.top - y) * scale,
    right: (box.right - x) * scale,
    bottom: (box.bottom - y) * scale,
  };
}
