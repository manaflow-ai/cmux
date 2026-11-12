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

/** `point` (layout viewport CSS px, a pointer's `clientX`/`clientY`) where it shows on the pinch-zoomed
 * screen, in unzoomed CSS px. */
export function pointOnVisualViewport(
  point: { x: number; y: number },
  view: Window | null | undefined,
): { x: number; y: number } {
  const box = onVisualViewport({ left: point.x, top: point.y, right: point.x, bottom: point.y }, view);
  return { x: box.left, y: box.top };
}

// The zoom a box was measured at (Leo, 2026-11-12, of the "Also working here" popover after a zoom:
// "evidently you zoom in and it doesn't really, you know, it doesn't follow, right?"). Cmd +/- and
// Interface Scale are a real page zoom: the App turns a box's CSS px into its points by that zoom. It
// read the zoom when it drew, not when the page measured, and both sides drop an unchanged report, so
// a popover whose CSS box stayed put across a zoom kept its glass at the old size under content drawn
// at the new one. Every box the App draws at now carries the zoom it was measured at, and every
// reporter measures again when the zoom changes (`cmux-ui-scale-change`), so the report differs and goes.

/** The App's event on the page's window when its zoom changes (DesignSettings.interfaceScaleScript). */
export const PAGE_ZOOM_EVENT = "cmux-ui-scale-change";

/** View points per CSS px the App draws this page at (`--cmux-ui-scale` on the root), 1 when unset. */
export function pageZoom(view: Window | null | undefined): number {
  const root = view?.document?.documentElement;
  const inline = root?.style?.getPropertyValue?.("--cmux-ui-scale") ?? "";
  const value = Number.parseFloat(
    inline || (root ? view!.getComputedStyle(root).getPropertyValue("--cmux-ui-scale") : ""),
  );
  return Number.isFinite(value) && value > 0 ? Math.round(value * 1000) / 1000 : 1;
}
