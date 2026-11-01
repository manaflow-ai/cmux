// The page's own blur under a floating glass in a see-through Chromium page (glass.css, "CHROMIUM
// OVER THE WINDOW GLASS"; Leo 2026-10-30: "I don't like the non-glassness"). Chromium draws a
// backdrop-filter's blurred copy over the page's own pixels, not in their place, so over a clear
// page the text under the glass stays sharp and reads through its tint. Here the elements under the
// glass blur themselves instead: each sibling of the surface it covers gets a CSS `filter` (an SVG
// filter this module writes) that blurs that element's own pixels inside the surface's rounded
// rect and leaves the rest of it untouched. The text under the glass is then blurred in place, as
// WebKit's backdrop draws it, and the glass needs no underlay to hide it (glass.css drops the
// underlay of a surface that carries data-glass-over). glass.css applies the filter only in a
// see-through Chromium page outside the lens and Reduce Transparency; an opaque page's backdrop
// already covers what is under it.
//
// Cost: nothing in WebKit (no listeners, no elements). In Chromium, while one surface is open: one
// hidden <svg> with a filter per covered sibling, a ResizeObserver on the surface and its parent,
// and a requestAnimationFrame loop that follows the surface while its rect or opacity changes
// (its enter and exit, a resize) and stops after STABLE_FRAMES unchanged frames. Each frame reads
// every rect first and writes only what changed. Closing the surface removes all of it.
import { type RefObject, useLayoutEffect } from "react";

const SVG_NS = "http://www.w3.org/2000/svg";
/** Unchanged frames before the follow loop stops. */
const STABLE_FRAMES = 3;
/** On an element under a surface: glass.css gives it `filter: var(--glass-under-filter)`. */
export const UNDER_ATTRIBUTE = "data-glass-under";
/** The custom property holding the element's own filter, `url(#…)`. */
export const UNDER_FILTER_PROPERTY = "--glass-under-filter";
/** On the surface while it blurs what is under it: glass.css drops its underlay. */
export const OVER_ATTRIBUTE = "data-glass-over";
/** The blur when the surface's own backdrop names none, CSS px (the plain glass blur). */
const FALLBACK_BLUR = 24;

/** The surface's rounded rect in a covered element's own box, and how the blur draws there. */
export type BlurHole = {
  x: number;
  y: number;
  width: number;
  height: number;
  radius: number;
  /** The Gaussian's standard deviation, CSS px: CSS `blur(r)` is a deviation of r. */
  blur: number;
  /** The surface's opacity: the blur fades in and out with it. */
  opacity: number;
};

/** The blur radius in a `backdrop-filter` value ("blur(24px) saturate(1.8)" is 24), else `fallback`. */
export function backdropBlurRadius(value: string | null | undefined, fallback = FALLBACK_BLUR): number {
  const match = /blur\(\s*([\d.]+)px\s*\)/.exec(value ?? "");
  const radius = match ? Number.parseFloat(match[1]!) : Number.NaN;
  return Number.isFinite(radius) && radius > 0 ? radius : fallback;
}

/** Whether the rects overlap with any area. */
export function overlaps(a: DOMRectReadOnly, b: DOMRectReadOnly): boolean {
  return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
}

/** The surface's hole in `target`'s own box (the filter's user space is the element's border box). */
export function holeIn(
  surface: DOMRectReadOnly,
  target: DOMRectReadOnly,
  style: { radius: number; blur: number; opacity: number },
): BlurHole {
  return {
    x: surface.left - target.left,
    y: surface.top - target.top,
    width: surface.width,
    height: surface.height,
    radius: Math.min(style.radius, surface.width / 2, surface.height / 2),
    blur: style.blur,
    opacity: Math.min(1, Math.max(0, style.opacity)),
  };
}

/** The hole's shape: a rounded rect of its own size, as an SVG data URL for feImage. */
export function holeMask(width: number, height: number, radius: number): string {
  const w = Math.max(1, Math.round(width));
  const h = Math.max(1, Math.round(height));
  const r = Math.max(0, Math.round(radius));
  return `data:image/svg+xml,${encodeURIComponent(
    `<svg xmlns="${SVG_NS}" width="${w}" height="${h}"><rect width="${w}" height="${h}" rx="${r}" ry="${r}"/></svg>`,
  )}`;
}

function primitive(doc: Document, name: string, attributes: Record<string, string>): SVGElement {
  const element = doc.createElementNS(SVG_NS, name) as SVGElement;
  for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, value);
  return element;
}

/** Builds a covered element's filter: the element as it is outside the hole, and inside it its own
 * pixels blurred (mixed with the sharp ones by the surface's opacity), cut to the rounded hole. */
export function createHoleFilter(doc: Document, id: string): SVGFilterElement {
  const filter = primitive(doc, "filter", {
    id,
    filterUnits: "userSpaceOnUse",
    primitiveUnits: "userSpaceOnUse",
    "color-interpolation-filters": "sRGB",
  }) as SVGFilterElement;
  filter.append(
    primitive(doc, "feGaussianBlur", { in: "SourceGraphic", result: "blurred" }),
    primitive(doc, "feComposite", {
      in: "blurred",
      in2: "SourceGraphic",
      operator: "arithmetic",
      k1: "0",
      k4: "0",
      result: "mixed",
    }),
    primitive(doc, "feImage", { preserveAspectRatio: "none", result: "hole" }),
    primitive(doc, "feComposite", { in: "mixed", in2: "hole", operator: "in", result: "inside" }),
    primitive(doc, "feComposite", { in: "SourceGraphic", in2: "hole", operator: "out", result: "outside" }),
  );
  const merge = primitive(doc, "feMerge", {});
  merge.append(primitive(doc, "feMergeNode", { in: "outside" }), primitive(doc, "feMergeNode", { in: "inside" }));
  filter.append(merge);
  return filter;
}

/** Writes `hole` into a filter made by createHoleFilter, for an element whose box is `box`. The
 * filter region is the element's whole box, so everything outside the hole passes through. */
export function writeHoleFilter(
  filter: SVGFilterElement,
  box: { width: number; height: number },
  hole: BlurHole,
): void {
  const set = (element: Element | undefined, attributes: Record<string, string | number>) => {
    for (const [key, value] of Object.entries(attributes)) element?.setAttribute(key, String(value));
  };
  const region = { x: hole.x, y: hole.y, width: hole.width, height: hole.height };
  const [blur, mixed, image] = [...filter.children];
  set(filter, { x: 0, y: 0, width: Math.max(1, box.width), height: Math.max(1, box.height) });
  set(blur, { ...region, stdDeviation: hole.blur });
  set(mixed, { ...region, k2: hole.opacity, k3: 1 - hole.opacity });
  set(image, { ...region, href: holeMask(hole.width, hole.height, hole.radius) });
}

/** Whether this engine draws a backdrop over the page's pixels (Chromium) rather than in their
 * place (WebKit, which keeps -webkit-backdrop-filter): glass.css's own test for the underlay. */
export function drawsBackdropOver(view: Window): boolean {
  return !(view as unknown as typeof globalThis).CSS.supports("-webkit-backdrop-filter", "none");
}

let nextId = 0;

/** Blurs, in place, what `surface` covers among its siblings while it is attached. Returns the
 * detach. Does nothing (and returns a no-op) where the engine's backdrop already does it. */
export function attachSeeThroughBlur(surface: HTMLElement): () => void {
  const doc = surface.ownerDocument;
  const view = doc.defaultView;
  const parent = surface.parentElement;
  if (!view || !parent || !drawsBackdropOver(view)) return () => {};
  const svg = doc.createElementNS(SVG_NS, "svg");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("width", "0");
  svg.setAttribute("height", "0");
  svg.style.cssText = "position:absolute;width:0;height:0;overflow:hidden;pointer-events:none";
  doc.body.append(svg);
  surface.setAttribute(OVER_ATTRIBUTE, "");
  const covered = new Map<HTMLElement, { filter: SVGFilterElement; key: string }>();
  let frame = 0;
  let stable = 0;
  let last = "";

  const release = (target: HTMLElement) => {
    const entry = covered.get(target);
    if (!entry) return;
    entry.filter.remove();
    target.removeAttribute(UNDER_ATTRIBUTE);
    target.style.removeProperty(UNDER_FILTER_PROPERTY);
    covered.delete(target);
  };

  // One pass: every rect and style read first, then only the changed writes.
  const measure = (): string => {
    const rect = surface.getBoundingClientRect();
    const style = view.getComputedStyle(surface);
    const look = {
      radius: Number.parseFloat(style.borderTopLeftRadius) || 0,
      blur: backdropBlurRadius(style.backdropFilter),
      opacity: Number.parseFloat(style.opacity),
    };
    if (!Number.isFinite(look.opacity)) look.opacity = 1;
    const under: { target: HTMLElement; box: DOMRect; hole: BlurHole; key: string }[] = [];
    for (const child of parent.children) {
      if (child === surface || !(child instanceof view.HTMLElement)) continue;
      const box = child.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0 || !overlaps(rect, box)) continue;
      const hole = holeIn(rect, box, look);
      under.push({ target: child, box, hole, key: JSON.stringify([box.width, box.height, hole]) });
    }
    const keep = new Set(under.map((entry) => entry.target));
    for (const target of covered.keys()) if (!keep.has(target)) release(target);
    for (const { target, box, hole, key } of under) {
      let entry = covered.get(target);
      if (!entry) {
        const filter = createHoleFilter(doc, `cmux-see-through-blur-${++nextId}`);
        svg.append(filter);
        entry = { filter, key: "" };
        covered.set(target, entry);
        target.setAttribute(UNDER_ATTRIBUTE, "");
        target.style.setProperty(UNDER_FILTER_PROPERTY, `url(#${filter.id})`);
      }
      if (entry.key !== key) {
        writeHoleFilter(entry.filter, box, hole);
        entry.key = key;
      }
    }
    return under.map((entry) => entry.key).join("|");
  };

  const tick = () => {
    frame = 0;
    const key = measure();
    stable = key === last ? stable + 1 : 0;
    last = key;
    if (stable < STABLE_FRAMES) frame = view.requestAnimationFrame(tick);
  };
  const kick = () => {
    stable = 0;
    if (!frame) frame = view.requestAnimationFrame(tick);
  };

  measure();
  kick();
  const resize = new ResizeObserver(kick);
  resize.observe(surface);
  resize.observe(parent);
  surface.addEventListener("transitionrun", kick);
  surface.addEventListener("animationstart", kick);
  view.addEventListener("resize", kick);
  return () => {
    if (frame) view.cancelAnimationFrame(frame);
    frame = 0;
    resize.disconnect();
    surface.removeEventListener("transitionrun", kick);
    surface.removeEventListener("animationstart", kick);
    view.removeEventListener("resize", kick);
    for (const target of covered.keys()) release(target);
    surface.removeAttribute(OVER_ATTRIBUTE);
    svg.remove();
  };
}

/** attachSeeThroughBlur for a React surface: attached while `active` and mounted. */
export function useSeeThroughBlur(surface: RefObject<HTMLElement | null>, active: boolean): void {
  useLayoutEffect(() => {
    const node = surface.current;
    if (!active || !node) return;
    return attachSeeThroughBlur(node);
  }, [surface, active]);
}
