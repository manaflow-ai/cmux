// The page's own blur under a floating glass in a see-through Chromium page (glass.css, "CHROMIUM
// OVER THE WINDOW GLASS"; Leo 2026-10-30: "I don't like the non-glassness"). Chromium draws a
// backdrop-filter's blurred copy over the page's own pixels, not in their place, so over a clear
// page the text under the glass stays sharp and reads through its tint. Here the elements under the
// glass blur themselves instead: each element it covers (its siblings, or a list the caller
// names) gets a CSS `filter` (an SVG filter this module writes) that blurs that element's own
// pixels inside the surface's rounded rect and leaves the rest of it untouched. The text under the glass is then blurred in place, as
// WebKit's backdrop draws it, and the glass needs no underlay to hide it (glass.css drops the
// underlay of a surface that carries data-glass-over). glass.css applies the filter only in a
// see-through Chromium page outside the lens and Reduce Transparency; an opaque page's backdrop
// already covers what is under it.
//
// Cost: nothing in WebKit (no listeners, no elements). In Chromium, while one surface is open: one
// hidden <svg> with a filter per covered element, a ResizeObserver on the surface, its parent and
// the candidates, a MutationObserver (direct children only, never the subtree) on the candidates'
// parents and on the surface's own inline style, and a requestAnimationFrame loop that follows the
// surface while its rect, opacity or visibility changes (its enter and exit, a resize, a move, a
// banner or Find bar coming in) and stops after STABLE_FRAMES unchanged frames. Each frame reads every rect first and writes only what changed.
// A change of the surface's own inline style alone (the rail's preview card moving to the next row by
// its transform) measures once on the next frame, not the loop: the new place is final when written.
// Closing the surface removes all of it. A window without those observers (a test DOM) gets nothing.
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
  style: { radius: number; blur: number },
): BlurHole {
  return {
    x: surface.left - target.left,
    y: surface.top - target.top,
    width: surface.width,
    height: surface.height,
    radius: Math.min(style.radius, surface.width / 2, surface.height / 2),
    blur: style.blur,
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
 * pixels blurred, cut to the rounded hole. The blur is all or nothing: a surface fading in or out
 * never draws its pixels part sharp, part blurred (Leo, 2026-10-26: "If we're doing blur, we're
 * doing blur. If we're not doing blur, we're not doing blur. We shouldn't have in-between states
 * ever. That cause flicker"). */
export function createHoleFilter(doc: Document, id: string): SVGFilterElement {
  const filter = primitive(doc, "filter", {
    id,
    filterUnits: "userSpaceOnUse",
    primitiveUnits: "userSpaceOnUse",
    "color-interpolation-filters": "sRGB",
  }) as SVGFilterElement;
  filter.append(
    primitive(doc, "feGaussianBlur", { in: "SourceGraphic", result: "blurred" }),
    primitive(doc, "feImage", { preserveAspectRatio: "none", result: "hole" }),
    primitive(doc, "feComposite", { in: "blurred", in2: "hole", operator: "in", result: "inside" }),
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
  const [blur, image] = [...filter.children];
  set(filter, { x: 0, y: 0, width: Math.max(1, box.width), height: Math.max(1, box.height) });
  set(blur, { ...region, stdDeviation: hole.blur });
  set(image, { ...region, href: holeMask(hole.width, hole.height, hole.radius) });
}

/** Whether this engine draws a backdrop over the page's pixels (Chromium) rather than in their
 * place (WebKit, which keeps -webkit-backdrop-filter): glass.css's own test for the underlay. */
export function drawsBackdropOver(view: Window): boolean {
  const css = (view as unknown as { CSS?: { supports?: unknown } }).CSS;
  if (typeof css?.supports !== "function") return false;
  return !(view as unknown as typeof globalThis).CSS.supports("-webkit-backdrop-filter", "none");
}

/** Whether the window has what the follow loop needs (a test DOM may lack them): without them the
 * surface keeps its underlay and nothing is attached. */
function canFollow(view: Window): boolean {
  const scope = view as unknown as Record<string, unknown>;
  return ["ResizeObserver", "MutationObserver", "requestAnimationFrame", "cancelAnimationFrame"].every(
    (name) => typeof scope[name] === "function",
  );
}

let nextId = 0;

/** Every surface's filter on each covered element, by surface: two glasses over one element (the
 * rail's preview card and the Summary popover, both over the transcript) each keep their own hole.
 * The element draws their filters one after the other and carries every owner, so one surface's
 * release takes out its own hole alone. */
const holesOn = new WeakMap<HTMLElement, Map<number, { owner: string; filter: string }>>();

/** Writes `target`'s filter list and owners from its holes, or clears both when it has none. */
function writeHoles(target: HTMLElement): void {
  const holes = [...(holesOn.get(target)?.values() ?? [])];
  if (holes.length === 0) {
    holesOn.delete(target);
    target.removeAttribute(UNDER_ATTRIBUTE);
    target.style.removeProperty(UNDER_FILTER_PROPERTY);
    return;
  }
  target.setAttribute(UNDER_ATTRIBUTE, [...new Set(holes.map((hole) => hole.owner))].join(" ").trim());
  target.style.setProperty(UNDER_FILTER_PROPERTY, holes.map((hole) => `url(#${hole.filter})`).join(" "));
}

/** The elements a surface may cover: by default its siblings. */
export type CoveredCandidates = (surface: HTMLElement) => Iterable<Element>;

const siblings: CoveredCandidates = (surface) => surface.parentElement?.children ?? [];

export type SeeThroughOptions = {
  /** A word of data-glass-under on what this surface covers (a list, matched with `~=`, when
   * several glasses cover one element), so a stylesheet can switch off one surface's filters. A
   * surface CSS hides with `visibility` must: its holes stay (summary.css does it for the Summary
   * card under Find, review and inspect). */
  owner?: string;
  /** Elements that must not take a filter (one would re-anchor their fixed menus: the composer).
   * While the surface overlaps one, it keeps its underlay, which hides what is under it there. */
  keepUnderlayOver?: CoveredCandidates;
};

/** Blurs, in place, what `surface` covers among `candidates` (its siblings by default) while it is
 * attached. Returns the detach. Does nothing (and returns a no-op) where the engine's backdrop
 * already does it. */
export function attachSeeThroughBlur(
  surface: HTMLElement,
  candidates: CoveredCandidates = siblings,
  { owner = "", keepUnderlayOver }: SeeThroughOptions = {},
): () => void {
  const doc = surface.ownerDocument;
  const view = doc.defaultView;
  const parent = surface.parentElement;
  if (!view || !parent || !drawsBackdropOver(view) || !canFollow(view)) return () => {};
  const self = ++nextId;
  const svg = doc.createElementNS(SVG_NS, "svg");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("width", "0");
  svg.setAttribute("height", "0");
  svg.style.cssText = "position:absolute;width:0;height:0;overflow:hidden;pointer-events:none";
  doc.body.append(svg);
  const covered = new Map<HTMLElement, { filter: SVGFilterElement; key: string }>();
  let frame = 0;
  let stable = 0;
  let last = "";
  /// Whether the frame asked for follows until STABLE_FRAMES unchanged frames (`kick`), or measures
  /// once (`moved`).
  let following = false;
  // Re-measure when anything the hole depends on changes: the surface (its size, its transitions),
  // each candidate's size, and the children of each candidate's parent (a banner or a Find bar
  // coming in moves the blocks, or hides the surface through a :has() rule, without resizing them).
  const kickSoon = () => kick();
  const resize = new view.ResizeObserver(kickSoon);
  const mutations = new view.MutationObserver(kickSoon);
  const watched = new Set<Element>();
  const watch = (element: Element, children: boolean) => {
    if (watched.has(element)) return;
    watched.add(element);
    resize.observe(element);
    if (children) mutations.observe(element, { childList: true });
  };

  const release = (target: HTMLElement) => {
    const entry = covered.get(target);
    if (!entry) return;
    entry.filter.remove();
    holesOn.get(target)?.delete(self);
    writeHoles(target);
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
    // A faded-out or empty surface covers nothing; any other covers in full. One CSS hides with visibility (the Summary card
    // under Find) keeps its holes, so they are right the moment it shows again with no event to see
    // it; the same CSS switches its blocks' filters off meanwhile (owner, summary.css).
    const shown = look.opacity > 0 && rect.width > 0 && rect.height > 0;
    const under: { target: HTMLElement; box: DOMRect; hole: BlurHole; key: string }[] = [];
    for (const child of candidates(surface)) {
      if (child === surface || child.contains(surface) || !(child instanceof view.HTMLElement)) continue;
      watch(child, false);
      if (child.parentElement) watch(child.parentElement, true);
      if (!shown) continue;
      const box = child.getBoundingClientRect();
      if (!overlaps(rect, box)) continue;
      const hole = holeIn(rect, box, look);
      under.push({ target: child, box, hole, key: JSON.stringify([box.width, box.height, hole]) });
    }
    let unblurrable = false;
    if (shown && keepUnderlayOver)
      for (const element of keepUnderlayOver(surface)) {
        watch(element, false);
        if (overlaps(rect, element.getBoundingClientRect())) unblurrable = true;
      }
    surface.toggleAttribute(OVER_ATTRIBUTE, !unblurrable);
    const keep = new Set(under.map((entry) => entry.target));
    for (const target of covered.keys()) if (!keep.has(target)) release(target);
    for (const { target, box, hole, key } of under) {
      let entry = covered.get(target);
      if (!entry) {
        const filter = createHoleFilter(doc, `cmux-see-through-blur-${++nextId}`);
        svg.append(filter);
        entry = { filter, key: "" };
        covered.set(target, entry);
        let holes = holesOn.get(target);
        if (!holes) holesOn.set(target, (holes = new Map()));
        holes.set(self, { owner, filter: filter.id });
        writeHoles(target);
      }
      if (entry.key !== key) {
        writeHoleFilter(entry.filter, box, hole);
        entry.key = key;
      }
    }
    return `${shown}|${unblurrable}|${under.map((entry) => entry.key).join("|")}`;
  };

  const tick = () => {
    frame = 0;
    const key = measure();
    stable = key === last ? stable + 1 : 0;
    last = key;
    if (following && stable < STABLE_FRAMES) frame = view.requestAnimationFrame(tick);
    else following = false;
  };
  const kick = () => {
    following = true;
    stable = 0;
    if (!frame) frame = view.requestAnimationFrame(tick);
  };
  /// The surface's inline style changed (a transform written in place, the rail's card reaching the
  /// next row): one measure on the next frame finds it where it draws. A move animates through CSS,
  /// whose transitionrun follows it (`kick`), and a size change is the ResizeObserver's. The loop
  /// restarted on every row a sweep crossed, about every 40 ms, so it never stopped: every frame of
  /// the sweep re-read the surface's rect and style and each covered element's rect (Leo,
  /// 2026-11-04: "hover previews kinda lag across me hovering over the sidebar stuff").
  const moved = () => {
    if (!frame) frame = view.requestAnimationFrame(tick);
  };
  const restyled = new view.MutationObserver(moved);

  watch(surface, false);
  watch(parent, true);
  // A surface placed by its own inline style (the rail's preview card follows the pointer from row
  // to row by its transform) moves with no resize or child change: its style measures again.
  restyled.observe(surface, { attributes: true, attributeFilter: ["style"] });
  measure();
  kick();
  surface.addEventListener("transitionrun", kick);
  // The loop may stop mid-fade (opacity is not in its key once shown): the fade's end measures again.
  surface.addEventListener("transitionend", kick);
  surface.addEventListener("animationstart", kick);
  view.addEventListener("resize", kick);
  return () => {
    if (frame) view.cancelAnimationFrame(frame);
    frame = 0;
    resize.disconnect();
    mutations.disconnect();
    restyled.disconnect();
    surface.removeEventListener("transitionrun", kick);
    surface.removeEventListener("transitionend", kick);
    surface.removeEventListener("animationstart", kick);
    view.removeEventListener("resize", kick);
    for (const target of covered.keys()) release(target);
    surface.removeAttribute(OVER_ATTRIBUTE);
    svg.remove();
  };
}

/** attachSeeThroughBlur for a React surface: attached while `active` and mounted. `candidates` must be
 * stable (module-level constants). */
export function useSeeThroughBlur(
  surface: RefObject<HTMLElement | null>,
  active: boolean,
  candidates?: CoveredCandidates,
  options?: SeeThroughOptions,
): void {
  useLayoutEffect(() => {
    const node = surface.current;
    if (!active || !node) return;
    return attachSeeThroughBlur(node, candidates, options);
  }, [surface, active, candidates, options]);
}
