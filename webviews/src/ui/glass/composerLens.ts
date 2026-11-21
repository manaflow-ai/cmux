// The composer's refraction lens over the live transcript (Leo, 2026-11-20: "Like, why not offer the
// option? I think it looks neat. I like the refraction. I think it's pretty darn close."). An option,
// never a replacement: it draws only while the host's Liquid Glass mode is Lens (GlassLensMode.swift,
// Debug Settings > Glass and Overlays > Liquid Glass, which puts `data-glass="lens"` on <html>, the
// same signal lens.ts reads). Plain stays exactly as it was.
//
// lens.ts bends a still of the wallpaper the host sends; it never sees the chat, which the page paints
// itself. This bends the page's own pixels: Chromium runs an SVG filter as a backdrop filter, so the
// composer box's backdrop (the transcript scrolling under it) goes through feDisplacementMap with a
// map shaped like the box, as a public write-up on CSS/SVG refraction does it: a convex squircle
// bezel, each rim pixel showing the point a vertical ray reaches after Snell refraction through it.
// WebKit draws nothing for an SVG backdrop filter, so there (and under Reduce Transparency) nothing
// attaches and the composer keeps its plain frost.
//
// Cost: the map is built once per box size (w x h x dpr x radius, cached, CACHE_MAX kept), when the
// box first shows at that size, and only after the size has held for SETTLE_MS (a box growing line by
// line, or animating, stretches the map it has meanwhile). A scroll or a new message changes no size:
// no script runs, and Chromium only re-samples the cached map in the filter it already runs for the
// frost. test/glass-composer-lens.test.ts fails if a scroll frame or a streamed row builds a map.
import { useLayoutEffect } from "react";
import { GLASS_ATTRIBUTE, resolveGlassMode } from "./glassState";
import { drawsBackdropOver } from "./seeThroughBlur";

/** On the composer box while its lens filter is ready: glass.css's "COMPOSER LENS" rule reads it. */
export const COMPOSER_LENS_ATTRIBUTE = "data-composer-lens";
/** The custom property holding the box's filter, `url(#…)`. */
export const COMPOSER_LENS_FILTER_PROPERTY = "--composer-lens-filter";

/** The glass's optics, CSS px: the bezel's width in from the rim, the slab's height at the top of
 * the bezel, the flat base under it, and the index of refraction (crown glass, as the engine's). */
export const LENS_OPTICS = { bezel: 18, thickness: 16, base: 4, ior: 1.5 } as const;
export type LensOptics = { bezel: number; thickness: number; base: number; ior: number };

/** The most map px a side; a larger box's map is stretched (the bend is smooth). */
const MAP_MAX = 2048;
const CACHE_MAX = 12;
/** A new size waits this long unchanged before its map is built (the box grows or animates). */
export const SETTLE_MS = 150;
const SVG_NS = "http://www.w3.org/2000/svg";

/** The convex squircle's height at `x`, 0 at the rim to 1 at the bezel's inner edge. */
export function squircle(x: number): number {
  const u = 1 - Math.min(1, Math.max(0, x));
  return Math.pow(1 - u * u * u * u, 0.25);
}

/** How far, CSS px, a vertical ray entering the bezel `inward` px in from the rim lands toward the
 * middle after refracting through the slab: (height there) x tan(incidence - refraction). */
export function snellShift(inward: number, optics: LensOptics = LENS_OPTICS): number {
  const { bezel, thickness, base, ior } = optics;
  if (bezel <= 0 || inward >= bezel) return 0;
  const x = Math.max(1e-4, inward / bezel);
  const u = 1 - x;
  const inner = 1 - u * u * u * u;
  // dh/d(inward): the squircle's slope, steep (a vertical wall) at the rim.
  const slope = (thickness / bezel) * u * u * u * Math.pow(inner, -0.75);
  const incidence = Math.atan(slope);
  const refracted = Math.asin(Math.sin(incidence) / ior);
  return (thickness * squircle(x) + base) * Math.tan(incidence - refracted);
}

/** The bezel's largest shift, CSS px: what one map unit (127) stands for. */
export function peakShift(optics: LensOptics = LENS_OPTICS): number {
  let peak = 0;
  for (let i = 0; i <= 256; i++) peak = Math.max(peak, snellShift((i / 256) * optics.bezel, optics));
  return peak;
}

/** The cache key: the box's size and corner in CSS px (rounded) and the device pixel ratio. */
export function lensMapKey(width: number, height: number, dpr: number, radius: number): string {
  const w = Math.max(1, Math.round(width));
  const h = Math.max(1, Math.round(height));
  const r = Math.max(0, Math.min(Math.round(radius), w / 2, h / 2));
  return `${w}x${h}@${Math.round(dpr * 100) / 100}r${r}`;
}

export type LensField = {
  key: string;
  /** Map px. */
  width: number;
  height: number;
  /** RGBA: red and green the inward pull (128 is none, 255 or 1 the peak), blue 128, alpha 255. */
  data: Uint8ClampedArray;
  /** CSS px one map unit stands for at 127: the filter's scale is twice it. */
  peak: number;
};

/** Builds so far, cache hits and misses: the tests and the bench read them. */
export const composerLensStats = { builds: 0, hits: 0 };

/** The displacement field for a rounded box of `width` x `height` CSS px at `dpr`, with corner
 * `radius`. Pure: no DOM. Each call is a build (composerLensStats.builds). */
export function buildLensField(
  width: number,
  height: number,
  dpr: number,
  radius: number,
  optics: LensOptics = LENS_OPTICS,
): LensField {
  composerLensStats.builds++;
  const w = Math.max(1, Math.round(width));
  const h = Math.max(1, Math.round(height));
  const r = Math.max(0, Math.min(Math.round(radius), w / 2, h / 2));
  const scale = Math.min(Math.max(1, dpr), MAP_MAX / Math.max(w, h));
  const mw = Math.max(2, Math.round(w * scale));
  const mh = Math.max(2, Math.round(h * scale));
  const data = new Uint8ClampedArray(mw * mh * 4);
  const peak = peakShift(optics) || 1;
  // The shift per whole CSS px in from the rim, read with a linear step between (no math per pixel).
  const steps = Math.ceil(optics.bezel) + 1;
  const table = new Float32Array(steps + 1);
  for (let i = 0; i <= steps; i++) table[i] = snellShift(i, optics) / peak;
  const halfW = w / 2;
  const halfH = h / 2;
  for (let y = 0; y < mh; y++) {
    const py = (y + 0.5) / scale - halfH;
    for (let x = 0; x < mw; x++) {
      const px = (x + 0.5) / scale - halfW;
      // The signed distance to the rounded rect (negative inside) and its outward normal.
      const qx = Math.abs(px) - (halfW - r);
      const qy = Math.abs(py) - (halfH - r);
      let nx = 0;
      let ny = 0;
      let outside: number;
      if (qx > 0 && qy > 0) {
        const length = Math.hypot(qx, qy);
        nx = (qx / length) * Math.sign(px);
        ny = (qy / length) * Math.sign(py);
        outside = length - r;
      } else if (qx > qy) {
        nx = Math.sign(px);
        outside = qx - r;
      } else {
        ny = Math.sign(py);
        outside = qy - r;
      }
      const inward = Math.max(0, -outside);
      let shift = 0;
      if (inward < optics.bezel) {
        const i = Math.floor(inward);
        const f = inward - i;
        shift = table[i]! * (1 - f) + table[Math.min(steps, i + 1)]! * f;
      }
      // feDisplacementMap samples at P + scale (C - 0.5): pulling in is minus the outward normal.
      const at = (y * mw + x) * 4;
      data[at] = Math.round(128 - 127 * nx * shift);
      data[at + 1] = Math.round(128 - 127 * ny * shift);
      data[at + 2] = 128;
      data[at + 3] = 255;
    }
  }
  return { key: lensMapKey(w, h, dpr, r), width: mw, height: mh, data, peak };
}

type CachedMap = { url: string; peak: number };
const cache = new Map<string, CachedMap>();

/** The cached map for a box, if it was built already (a hit moves it to the newest end). */
export function cachedLensMap(key: string): CachedMap | undefined {
  const hit = cache.get(key);
  if (hit) {
    cache.delete(key);
    cache.set(key, hit);
    composerLensStats.hits++;
  }
  return hit;
}

/** The map for a box as a PNG data URL and its peak (CSS px), built once per key. The URL is ""
 * where the document draws no canvas (a test DOM): the build still counts. */
export function composerLensMap(
  doc: Document,
  width: number,
  height: number,
  dpr: number,
  radius: number,
): CachedMap & { key: string } {
  const key = lensMapKey(width, height, dpr, radius);
  const hit = cachedLensMap(key);
  if (hit) return { key, ...hit };
  const field = buildLensField(width, height, dpr, radius);
  let url = "";
  const canvas = doc.createElement("canvas");
  const context = typeof canvas.getContext === "function" ? canvas.getContext("2d") : null;
  if (context) {
    canvas.width = field.width;
    canvas.height = field.height;
    const image = context.createImageData(field.width, field.height);
    image.data.set(field.data);
    context.putImageData(image, 0, 0);
    url = canvas.toDataURL("image/png");
  }
  const entry = { url, peak: field.peak };
  if (cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value!);
  cache.set(key, entry);
  return { key, ...entry };
}

/** Empties the map cache (tests). */
export function resetComposerLensCache(): void {
  cache.clear();
  composerLensStats.builds = 0;
  composerLensStats.hits = 0;
}

let nextId = 0;

function element(doc: Document, name: string, attributes: Record<string, string>): SVGElement {
  const node = doc.createElementNS(SVG_NS, name) as SVGElement;
  for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
  return node;
}

/**
 * Bends what is under `box` with its lens while attached: one hidden <svg> with the box's filter,
 * a ResizeObserver on the box and a window resize listener (a device pixel ratio change). Nothing
 * listens to scrolling or to the transcript. Returns the detach.
 */
export function attachComposerLens(box: HTMLElement): () => void {
  const doc = box.ownerDocument;
  const view = doc.defaultView;
  if (!view || typeof view.ResizeObserver !== "function") return () => {};
  const id = `cmux-composer-lens-${++nextId}`;
  const svg = element(doc, "svg", { "aria-hidden": "true", width: "0", height: "0", focusable: "false" });
  svg.style.cssText = "position:absolute;width:0;height:0;overflow:hidden;pointer-events:none";
  const filter = element(doc, "filter", {
    id,
    x: "0",
    y: "0",
    filterUnits: "userSpaceOnUse",
    primitiveUnits: "userSpaceOnUse",
    "color-interpolation-filters": "sRGB",
  });
  const map = element(doc, "feImage", { x: "0", y: "0", preserveAspectRatio: "none", result: "map" });
  const bend = element(doc, "feDisplacementMap", {
    in: "SourceGraphic",
    in2: "map",
    scale: "0",
    xChannelSelector: "R",
    yChannelSelector: "G",
    result: "moved",
  });
  // feDisplacementMap takes the nearest source pixel, which leaves bent text jagged; a third of a
  // pixel smooths it without frosting the words (the rule's own blur frosts after).
  const smooth = element(doc, "feGaussianBlur", { in: "moved", stdDeviation: "0.35", result: "bent" });
  // Under the bent copy, the surface: in a see-through page Chromium draws the backdrop over the
  // page's own pixels, so a clear copy would show the text twice (as the fisheye does).
  const surface = element(doc, "feFlood", { result: "surface" });
  surface.style.setProperty("flood-color", "var(--glass-surface, Canvas)");
  const merge = element(doc, "feMerge", {});
  merge.append(element(doc, "feMergeNode", { in: "surface" }), element(doc, "feMergeNode", { in: "bent" }));
  filter.append(map, bend, smooth, surface, merge);
  svg.append(filter);
  doc.body.append(svg);

  let shown = "";
  let pending = "";
  let timer = 0;
  const apply = (width: number, height: number, entry: CachedMap & { key: string }) => {
    for (const node of [filter, map]) {
      node.setAttribute("width", String(width));
      node.setAttribute("height", String(height));
    }
    if (entry.url) map.setAttribute("href", entry.url);
    // feDisplacementMap moves a pixel by scale (C - 0.5): the most, at 255, is scale / 2.
    bend.setAttribute("scale", String(entry.peak * 2));
    shown = entry.key;
    if (!entry.url) return;
    box.style.setProperty(COMPOSER_LENS_FILTER_PROPERTY, `url(#${id})`);
    box.setAttribute(COMPOSER_LENS_ATTRIBUTE, "");
  };
  const measure = () => {
    const width = box.offsetWidth;
    const height = box.offsetHeight;
    if (width < 1 || height < 1) return;
    const dpr = view.devicePixelRatio || 1;
    const radius = Number.parseFloat(view.getComputedStyle(box).borderTopLeftRadius) || 0;
    const key = lensMapKey(width, height, dpr, radius);
    if (key === shown) return;
    const hit = cachedLensMap(key);
    if (hit) {
      // The filter region follows the box at once; the map it has is the size's own.
      if (timer) view.clearTimeout(timer);
      timer = 0;
      apply(width, height, { key, ...hit });
      return;
    }
    if (!shown) {
      apply(width, height, composerLensMap(doc, width, height, dpr, radius));
      return;
    }
    // A size with no map yet: the map it has stretches over the new box until the size holds.
    for (const node of [filter, map]) {
      node.setAttribute("width", String(width));
      node.setAttribute("height", String(height));
    }
    if (pending === key && timer) return;
    pending = key;
    if (timer) view.clearTimeout(timer);
    timer = view.setTimeout(() => {
      timer = 0;
      if (lensMapKey(box.offsetWidth, box.offsetHeight, view.devicePixelRatio || 1, radius) !== key) return measure();
      apply(width, height, composerLensMap(doc, width, height, dpr, radius));
    }, SETTLE_MS);
  };
  const observer = new view.ResizeObserver(() => measure());
  observer.observe(box);
  view.addEventListener("resize", measure);
  measure();
  return () => {
    if (timer) view.clearTimeout(timer);
    observer.disconnect();
    view.removeEventListener("resize", measure);
    box.removeAttribute(COMPOSER_LENS_ATTRIBUTE);
    box.style.removeProperty(COMPOSER_LENS_FILTER_PROPERTY);
    svg.remove();
  };
}

const REDUCE_TRANSPARENCY = "(prefers-reduced-transparency: reduce)";

/** Whether the page draws the composer lens: the host's mode is Lens, no Reduce Transparency (the
 * system's or the host's), and an engine that runs an SVG backdrop filter (Chromium). */
export function wantsComposerLens(root: HTMLElement, view: Window): boolean {
  const reduce =
    root.hasAttribute("data-reduce-transparency") ||
    (typeof view.matchMedia === "function" && view.matchMedia(REDUCE_TRANSPARENCY).matches);
  return resolveGlassMode(root.getAttribute(GLASS_ATTRIBUTE), reduce) === "lens" && drawsBackdropOver(view);
}

/** Attaches the lens to `box` while the page wants it (wantsComposerLens), following the host's mode
 * and Reduce Transparency as they change. Returns the stop. */
export function watchComposerLens(box: HTMLElement): () => void {
  const doc = box.ownerDocument;
  const view = doc.defaultView;
  if (!view || typeof view.MutationObserver !== "function") return () => {};
  const root = doc.documentElement;
  let detach: (() => void) | null = null;
  const update = () => {
    const on = wantsComposerLens(root, view);
    if (on && !detach) detach = attachComposerLens(box);
    else if (!on && detach) {
      detach();
      detach = null;
    }
  };
  const observer = new view.MutationObserver(update);
  observer.observe(root, { attributes: true, attributeFilter: [GLASS_ATTRIBUTE, "data-reduce-transparency"] });
  const media = typeof view.matchMedia === "function" ? view.matchMedia(REDUCE_TRANSPARENCY) : null;
  media?.addEventListener?.("change", update);
  update();
  return () => {
    observer.disconnect();
    media?.removeEventListener?.("change", update);
    detach?.();
    detach = null;
  };
}

/** watchComposerLens for the composer's box element while it is mounted. */
export function useComposerLens(box: HTMLElement | null): void {
  useLayoutEffect(() => {
    if (!box) return;
    return watchComposerLens(box);
  }, [box]);
}
