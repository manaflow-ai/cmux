// The pure half of the liquid glass lens (plans/cmux-next/glass-lens-DESIGN.md): the host's backdrop
// payload and its merge, the effective glass mode, and the lens geometry the shader mirrors
// (lens.ts). Nothing here touches WebGL, so unit tests run it as is.

/** The effective glass mode: the host's `data-glass` on `<html>`, plain under Reduce Transparency. */
export type GlassMode = "lens" | "plain" | "spectrum";

/** The art's aspect-filled rect, in the page's CSS px relative to its viewport. */
export type BackdropRect = { x: number; y: number; width: number; height: number };

/** `window.cmuxBackdropState`: what `cmuxTheme.backdrop(partial)` has merged so far. */
export type BackdropState = {
  /** The art as drawn, before its blur (`data:image/jpeg`), or null when there is nothing still. */
  image: string | null;
  /** Changes exactly when `image` changes. */
  key: string | null;
  rect: BackdropRect | null;
  /** The art's own blur radius, CSS px. */
  blur: number;
  /** The native wash over the art, a CSS color with alpha. */
  tint: string;
};

/** The event `cmuxTheme.backdrop` dispatches on `window` after each merge. */
export const BACKDROP_EVENT = "cmux-backdrop";
/** The host's effective mode on `<html>`. */
export const GLASS_ATTRIBUTE = "data-glass";
/** On `<html>` while the lens draws: `.ui-glass` drops its own backdrop blur (glass.css). */
export const LENS_ATTRIBUTE = "data-glass-lens";
/** On `<html>` of a page whose host draws the glass natively under it (the sidebar's Updated card,
 * surface.tsx): the lens draws nothing there, since its wallpaper copy would cover the host's glass. */
export const NATIVE_GLASS_ATTRIBUTE = "data-glass-native";
/** The one class a glass surface adds. */
export const GLASS_CLASS = "ui-glass";

export const EMPTY_BACKDROP: BackdropState = { image: null, key: null, rect: null, blur: 0, tint: "transparent" };

function finite(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function validRect(value: unknown): BackdropRect | null | undefined {
  if (value === null) return null;
  if (typeof value !== "object" || value === undefined) return undefined;
  const { x, y, width, height } = value as Record<string, unknown>;
  return finite(x) && finite(y) && finite(width) && finite(height) && width > 0 && height > 0
    ? { x, y, width, height }
    : undefined;
}

/** Merges one host payload into the state: absent or malformed fields keep their value, and a new
 * `key` without an `image` keeps the old image (the host sends the image only when it changes). */
export function mergeBackdrop(state: BackdropState, partial: unknown): BackdropState {
  if (typeof partial !== "object" || partial === null) return state;
  const next: BackdropState = { ...state };
  const input = partial as Record<string, unknown>;
  if ("image" in input && (input.image === null || typeof input.image === "string")) next.image = input.image || null;
  if ("key" in input && (input.key === null || typeof input.key === "string" || finite(input.key)))
    next.key = input.key === null ? null : String(input.key);
  if ("rect" in input) {
    const rect = validRect(input.rect);
    if (rect !== undefined) next.rect = rect;
  }
  if (finite(input.blur) && input.blur >= 0) next.blur = input.blur;
  if (typeof input.tint === "string" && input.tint.trim()) next.tint = input.tint;
  return next;
}

/** The mode the page draws: plain under Reduce Transparency (the system's or the host's), else the
 * host's `data-glass`, else plain (the default; the lens is opt-in). */
export function resolveGlassMode(attribute: string | null, reduceTransparency: boolean): GlassMode {
  if (reduceTransparency) return "plain";
  return attribute === "lens" || attribute === "spectrum" ? attribute : "plain";
}

/** The lens's cross-section: 1 at the rim (t = 0), 0 from the band's inner edge (t = 1) on, with a
 * quarter-circle profile so the bend is steep at the edge and meets the flat center smoothly. */
export function lensProfile(t: number): number {
  const u = Math.min(1, Math.max(0, t));
  return 1 - Math.sqrt(Math.max(0, u * (2 - u)));
}

/** Signed distance from a point (relative to the box center) to a rounded rect of half size
 * `halfW` x `halfH` and corner `radius`: negative inside. */
export function roundedRectSdf(px: number, py: number, halfW: number, halfH: number, radius: number): number {
  const r = Math.min(radius, halfW, halfH);
  const qx = Math.abs(px) - (halfW - r);
  const qy = Math.abs(py) - (halfH - r);
  const outside = Math.hypot(Math.max(qx, 0), Math.max(qy, 0));
  return outside + Math.min(Math.max(qx, qy), 0) - r;
}

/** The rim band's width: about three times the bend, never past the box's half size. */
export function rimBand(refraction: number, halfW: number, halfH: number): number {
  return Math.min(Math.min(halfW, halfH), Math.max(refraction * 3, 8));
}

/** How far (CSS px, inward) a point at signed distance `sdf` samples: `refraction` at the rim. */
export function lensDisplacement(sdf: number, refraction: number, band: number): number {
  if (sdf >= 0 || band <= 0) return 0;
  return refraction * lensProfile(-sdf / band);
}

/** The per-channel bend under Spectrum (R, G, B): 1, 1 + d, 1 + 2d. Lens and plain bend all alike. */
export function channelStrengths(mode: GlassMode, dispersion: number): [number, number, number] {
  if (mode !== "spectrum") return [1, 1, 1];
  const d = Math.max(0, dispersion);
  return [1, 1 + d, 1 + 2 * d];
}

/** The smallest power of two at or above `n`, capped. Mipmapped textures need one in WebGL1. */
export function powerOfTwo(n: number, cap = 1024): number {
  let size = 1;
  while (size < n && size < cap) size *= 2;
  return size;
}

type BackdropWindow = Window & {
  cmuxBackdropState?: BackdropState;
  cmuxTheme?: Record<string, unknown> & { backdrop?: (partial: unknown) => void };
};

/** Defines `window.cmuxTheme.backdrop` when the host bootstrap did not (tests, the plain-browser
 * dev loop, gallery fixtures), with the bootstrap's semantics: merge into `cmuxBackdropState`, then
 * dispatch `cmux-backdrop`. Never replaces the host's. */
export function installBackdropFallback(view: Window): void {
  const win = view as BackdropWindow;
  win.cmuxBackdropState ??= { ...EMPTY_BACKDROP };
  // The host's bootstrap is a document-start script, so in the app it has run by now. A page with
  // no host (tests, the dev loop) gets a stand-in whose `apply` does nothing, as callers that write
  // `cmuxTheme?.apply(...)` found before.
  const theme = (win.cmuxTheme ??= { current: null, apply: () => undefined });
  if (typeof theme.backdrop === "function") return;
  theme.backdrop = (partial: unknown) => {
    win.cmuxBackdropState = mergeBackdrop(win.cmuxBackdropState ?? EMPTY_BACKDROP, partial);
    view.dispatchEvent(new CustomEvent(BACKDROP_EVENT, { detail: win.cmuxBackdropState }));
  };
}

/** The merged backdrop state the host (or the fallback) keeps on `window`. */
export function readBackdrop(view: Window): BackdropState {
  const state = (view as BackdropWindow).cmuxBackdropState;
  return state ? mergeBackdrop(EMPTY_BACKDROP, state) : EMPTY_BACKDROP;
}
