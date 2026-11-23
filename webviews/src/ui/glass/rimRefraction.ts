// The rim of a floating glass bends what is under it (Leo, 2026-11-07: "are we able to get the edge
// refraction like in ios? that's what ive been missing a lot of tbh like the little bumps and grooves
// and whatnot with more actual glass EFFECTS where it gets sometiems a little smooshed").
//
// The App's own glass under a see-through Chromium page (hostGlass.ts) is the system's Liquid Glass
// in the same window as the background art, so its lens bends the art. It never sees the page: the
// chat under a menu is Chromium's, drawn over the App's glass, and the page blurs it in place
// (seeThroughBlur.ts). So the page bends it itself, in the same SVG filter that blurs it: a
// displacement map shaped like the surface's rounded rect pulls the pixels near the rim in from
// further inside (they squeeze toward the edge, as a thick glass's rim does), and across a band at the
// rim the bent copy, only lightly blurred, cross-fades into the frosted middle. The middle is
// unchanged, so the surface's own text keeps the frost it reads on.
//
// Cost: one map per surface size (a canvas of at most MAP_MAX px a side, cached), drawn when a
// surface first opens at that size; Chromium runs the displacement inside the filter it already runs
// for the blur, only when what is under the surface changes. None under Reduce Transparency, in
// WebKit or under the lens: glass.css applies the page's filter in none of them.

/** How strongly a rim bends: its band, CSS px from the edge in; the most a pixel moves, CSS px (at
 * the very edge); and the blur on the bent copy (a Gaussian deviation, CSS px). */
export type Refraction = { band: number; shift: number; blur: number };

/** The strengths a surface may ask for with `--glass-refract` (glass.css). */
export const REFRACTIONS = {
  none: { band: 0, shift: 0, blur: 0 },
  /** A hint of a rim: the edge squeezes a little, still mostly frosted. */
  subtle: { band: 10, shift: 6, blur: 2 },
  /** The shipped strength: a clear lensed rim like the system's own popovers. */
  ios: { band: 18, shift: 14, blur: 1.5 },
  /** A thick slab: the rim pulls the content a long way in and barely frosts it. */
  strong: { band: 26, shift: 24, blur: 1 },
} as const satisfies Record<string, Refraction>;
export type RefractionName = keyof typeof REFRACTIONS;
export const REFRACTION_DEFAULT: RefractionName = "ios";

/** The strength a `--glass-refract` value names; unset or unknown takes the default. */
export function refractionNamed(value: string | null | undefined): Refraction {
  const name = (value ?? "").trim();
  return Object.hasOwn(REFRACTIONS, name) ? REFRACTIONS[name as RefractionName] : REFRACTIONS[REFRACTION_DEFAULT];
}

/** The longest side of a map, map px; a larger surface's map is stretched (the bend is smooth). */
const MAP_MAX = 256;
/** Map px per CSS px below MAP_MAX: half resolution is plenty for a smooth bend. */
const MAP_SCALE = 0.5;
/** Sizes are rounded to this many CSS px for the cache, so a surface scaling in reuses its maps. */
const SIZE_STEP = 8;
const CACHE_MAX = 16;
const cache = new Map<string, string>();

/** One map pixel: red and green the inward pull (128 is none), blue the rim's weight. */
export function rimPixel(
  x: number,
  y: number,
  width: number,
  height: number,
  radius: number,
  band: number,
): [number, number, number] {
  // The signed distance to the rounded rect (negative inside) and its outward normal.
  const px = x - width / 2;
  const py = y - height / 2;
  const qx = Math.abs(px) - (width / 2 - radius);
  const qy = Math.abs(py) - (height / 2 - radius);
  let nx: number;
  let ny: number;
  let outside: number;
  if (qx > 0 && qy > 0) {
    const length = Math.hypot(qx, qy);
    nx = (qx / length) * Math.sign(px);
    ny = (qy / length) * Math.sign(py);
    outside = length - radius;
  } else if (qx > qy) {
    nx = Math.sign(px);
    ny = 0;
    outside = qx - radius;
  } else {
    nx = 0;
    ny = Math.sign(py);
    outside = qy - radius;
  }
  const inward = Math.max(0, -outside);
  if (band <= 0 || inward >= band) return [128, 128, 0];
  const t = inward / band;
  // A quarter circle: the rim pulls hardest at the edge and lets go smoothly at the band's end.
  const bend = 1 - Math.sqrt(t * (2 - t));
  // feDisplacementMap samples at P + scale (C - 0.5): pulling in is minus the outward normal.
  const weight = 1 - t * t * (3 - 2 * t);
  return [Math.round(128 - 127 * nx * bend), Math.round(128 - 127 * ny * bend), Math.round(255 * weight)];
}

/** The map for a rounded rect of `width` x `height` CSS px, as a PNG data URL; "" with no rim or
 * no canvas (a test DOM). */
export function rimMap(doc: Document, width: number, height: number, radius: number, refraction: Refraction): string {
  if (refraction.band <= 0 || refraction.shift <= 0 || width < 1 || height < 1) return "";
  const w = Math.max(SIZE_STEP, Math.round(width / SIZE_STEP) * SIZE_STEP);
  const h = Math.max(SIZE_STEP, Math.round(height / SIZE_STEP) * SIZE_STEP);
  const r = Math.min(Math.round(radius), w / 2, h / 2);
  const key = `${w}x${h}r${r}b${refraction.band}`;
  const hit = cache.get(key);
  if (hit !== undefined) return hit;
  const scale = Math.min(MAP_SCALE, MAP_MAX / Math.max(w, h));
  const mw = Math.max(2, Math.round(w * scale));
  const mh = Math.max(2, Math.round(h * scale));
  const canvas = doc.createElement("canvas");
  canvas.width = mw;
  canvas.height = mh;
  const context = typeof canvas.getContext === "function" ? canvas.getContext("2d") : null;
  if (!context) return "";
  const image = context.createImageData(mw, mh);
  for (let y = 0; y < mh; y++) {
    for (let x = 0; x < mw; x++) {
      const [red, green, blue] = rimPixel((x + 0.5) / scale, (y + 0.5) / scale, w, h, r, refraction.band);
      const at = (y * mw + x) * 4;
      image.data[at] = red;
      image.data[at + 1] = green;
      image.data[at + 2] = blue;
      image.data[at + 3] = 255;
    }
  }
  context.putImageData(image, 0, 0);
  const url = canvas.toDataURL("image/png");
  if (cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value!);
  cache.set(key, url);
  return url;
}
