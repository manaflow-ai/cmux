// The Text Size (interface scale) a floating surface's geometry follows (Leo, 2026-11-12: "evidently
// you zoom in and it doesn't really, you know, it doesn't follow"). Cmd +/- is a page zoom, so px
// follow it already; Text Size and density are not: the App writes `--cmux-interface-scale` on <html>
// (DesignSettings.interfaceScaleScript) and dispatches `cmux-ui-scale-change`. Text sized by the type
// tokens grows with it, so a popover, card or chip placed with a px literal clips its own label.
//
// CSS uses `--ui-px` (ui/popupSurface.css): one px at the interface scale, `calc(320 * var(--ui-px, 1px))`.
// JS geometry (a width a clamp reckons with, the height that picks a side) uses `scaledPx` here, read
// when it places, and `onInterfaceScaleChange` to place again when the scale changes while open.
// The tooltip's gap (tooltipTokens.ts) reads the same value.

/** The event the App dispatches on the page's window after it writes new scale tokens. */
export const INTERFACE_SCALE_EVENT = "cmux-ui-scale-change";

/** The page's interface scale (Text Size over the default), 1 with none to read. */
export function interfaceScale(view?: Window | null, root?: Element | null): number {
  const win = view === undefined ? (typeof window === "undefined" ? null : window) : view;
  root ??= win?.document?.documentElement;
  if (!win || !root || typeof win.getComputedStyle !== "function") return 1;
  const value = Number.parseFloat(win.getComputedStyle(root).getPropertyValue("--cmux-interface-scale"));
  return Number.isFinite(value) && value > 0 ? value : 1;
}

/** `px` at the interface scale of `view` (the page's window by default), CSS px. */
export function scaledPx(px: number, view?: Window | null): number {
  return px * interfaceScale(view);
}

/** The window an element's geometry is read in, if it has one. */
export function viewOf(node: { ownerDocument?: Document | null } | null | undefined): Window | null {
  return node?.ownerDocument?.defaultView ?? null;
}

/** Calls `listener` each time the App changes the scale tokens on `view`; returns the unsubscribe. */
export function onInterfaceScaleChange(listener: () => void, view?: Window | null): () => void {
  const win = view === undefined ? (typeof window === "undefined" ? null : window) : view;
  if (!win) return () => {};
  win.addEventListener(INTERFACE_SCALE_EVENT, listener);
  return () => win.removeEventListener(INTERFACE_SCALE_EVENT, listener);
}
