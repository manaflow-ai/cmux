// HIGHLIGHT-CONTRAST: the one rule for every fill drawn behind text to mark it (the text selection,
// Find's matches and its current match) on every page and in the agent chat. A highlight starts from
// its theme color (the Ghostty config's selection color, the theme's find highlight) and keeps it
// whenever it already reads; on a surface where it does not (a chat bubble, a card, a code block,
// glass, either theme) only its OKLCH lightness moves, step by step away from the surface, until
// the fill stands out from what it sits on and the text on it still reads (Leo 2026-11-07: "the
// highlight, I feel like it needs to be able to, like, auto-recognize what kind of thing, and ...
// change the hover, the highlight color, like starting from whichever one it was at ... it's about,
// like, in relation to, say, some of the bubbles").
//
// The floors are WCAG 2 contrast ratios. A highlight sits behind text, so the WCAG 1.4.11 3:1 for
// UI parts is kept for the current Find match only (with its text kept readable on it); the other
// matches and a selection keep a smaller, still clearly visible step from the surface, and every
// highlight keeps its text at WCAG AA (4.5:1), or, for text already fainter than that on its surface,
// all the contrast the fill's step leaves it.
import { parseComputedColor, type RGBA } from "../backdrop";
import { contrast, fromOklch, toOklch, BLACK, WHITE, type RGB } from "../theme/color";

/** How far a highlight's fill must stand from its surface, and its text from the fill. */
export type HighlightFloor = {
  /** WCAG 2 contrast of the fill against the surface under it. */
  surface: number;
  /** WCAG 2 contrast of the text against the fill. */
  ink: number;
};

export const HIGHLIGHT_FLOORS = {
  /** Selected text: plainly marked (the system light selection, #b3d7ff on white, is 1.4), its text as
   * readable as before. */
  selection: { surface: 1.3, ink: 4.5 },
  /** Find's other matches: a softer mark than the current one. */
  findMatch: { surface: 1.3, ink: 4.5 },
  /** Find's current match: the UI-part floor, so it is found at a glance among the others. */
  findCurrent: { surface: 3, ink: 4.5 },
} as const satisfies Record<string, HighlightFloor>;

/** One highlight fit to a surface: its fill and the text color to draw on it. */
export type FitHighlight = { fill: RGB; ink: RGB };

const LIGHTNESS_STEP = 0.01;

/** `top` over the opaque `bottom`, channels 0...1. */
export function over(top: RGBA, bottom: RGB): RGB {
  const a = top.a;
  return {
    r: (top.r / 255) * a + bottom.r * (1 - a),
    g: (top.g / 255) * a + bottom.g * (1 - a),
    b: (top.b / 255) * a + bottom.b * (1 - a),
  };
}

/**
 * The color macOS WebKit paints for an opaque `::selection` background: it never paints one as is,
 * but the translucent color (alpha 0.6, 0.667, 0.733 or 0.8, the least whose channels stay >= 0)
 * that over white looks like it (Color::blendWithWhite). A translucent color is kept.
 */
export function webKitSelectionColor(color: RGBA): RGBA {
  if (color.a < 1) return color;
  for (const alpha of [0.6, 0.667, 0.733, 0.8]) {
    const channel = (value: number) => (value - 255 * (1 - alpha)) / alpha;
    if ([color.r, color.g, color.b].every((value) => channel(value) >= 0))
      return { r: channel(color.r), g: channel(color.g), b: channel(color.b), a: alpha };
  }
  return color;
}

/** The best of `ink` and the other of black and white for text on `fill`. */
const readableInk = (fill: RGB): RGB => (contrast(BLACK, fill) >= contrast(WHITE, fill) ? BLACK : WHITE);

/** Room kept for a fainter text's floor: hue and chroma make the ratios multiply only roughly. */
const INK_SLACK = 1.15;

/**
 * `base` (as it draws over `surface`) fit to the floors: unchanged when it passes, else its OKLCH
 * lightness stepped away from the surface (toward the text first, then the other way) until fill
 * and text both pass. With `freeInk` the text may change too (Find's current match draws its own
 * text color): the more readable of black and white is tried after it. With no passing step it
 * returns the step closest to passing, which never trades the text's legibility for the fill's.
 */
export function fitHighlight(
  base: RGBA,
  surface: RGB,
  ink: RGB,
  floor: HighlightFloor,
  options: { freeInk?: boolean } = {},
): FitHighlight {
  return fitHighlightOn(base, [surface], ink, floor, options);
}

/**
 * The fit for every surface at once (a selection that starts on a bubble and ends on the page): it
 * starts from the base over the surface it reads worst on and passes only when it passes on all of
 * them, as `fitHighlight` does for one.
 */
export function fitHighlightOn(
  base: RGBA,
  surfaces: readonly RGB[],
  ink: RGB,
  floor: HighlightFloor,
  options: { freeInk?: boolean } = {},
): FitHighlight {
  if (!surfaces.length) return { fill: over(base, WHITE), ink };
  let worst = surfaces[0]!;
  for (const surface of surfaces)
    if (contrast(over(base, surface), surface) < contrast(over(base, worst), worst)) worst = surface;
  const start = over(base, worst);
  // The page's own text color (a selection, the other matches) keeps what the fill's step from the
  // surface leaves it when it is fainter than that already: contrast ratios multiply along lightness,
  // so asking more could never pass. A color the highlight draws its text in itself (`freeInk`, Find's
  // current match) is chosen for the fill and always keeps AA, switching to black or white if needed.
  const inkFloor = (text: RGB, surface: RGB) =>
    options.freeInk ? floor.ink : Math.min(floor.ink, contrast(text, surface) / (floor.surface * INK_SLACK));
  const score = (fill: RGB, text: RGB) =>
    Math.min(
      ...surfaces.map((surface) =>
        Math.min(contrast(fill, surface) / floor.surface, contrast(text, fill) / inkFloor(text, surface)),
      ),
    );
  const readable = (fill: RGB, text: RGB) =>
    surfaces.every((surface) => contrast(text, fill) >= inkFloor(text, surface));
  if (score(start, ink) >= 1) return { fill: start, ink };
  // A highlight that draws its own text may take black or white where its own color cannot pass
  // (a 3:1 fill on a light gray surface is dark, and needs white text).
  const inks = options.freeInk ? [ink, BLACK, WHITE] : [ink];
  let best: FitHighlight = { fill: start, ink };
  let bestScore = score(start, ink);
  const origin = toOklch(start);
  const surfaceLightness = toOklch(worst).l;
  for (const text of inks) {
    const textLightness = toOklch(text).l;
    const toward = textLightness !== surfaceLightness ? Math.sign(textLightness - surfaceLightness) : 1;
    for (const direction of [toward, -toward]) {
      for (let l = origin.l; l >= 0 && l <= 1; l += direction * LIGHTNESS_STEP) {
        const fill = fromOklch({ ...origin, l });
        const value = score(fill, text);
        if (value >= 1) return { fill, ink: text };
        if (value > bestScore) {
          best = { fill, ink: text };
          bestScore = value;
        }
        // Toward the text, past the point where it stops reading on the fill, no further step helps.
        if (direction === toward && !readable(fill, text)) break;
      }
    }
  }
  return best;
}

/** A CSS color for `color`. Translucent by a hair, so WebKit paints a selection in it as is (an
 * opaque one it blends with white, webKitSelectionColor). */
export function highlightCss(color: RGB): string {
  const channel = (value: number) => Math.round(Math.min(Math.max(value, 0), 1) * 255);
  return `rgb(${channel(color.r)} ${channel(color.g)} ${channel(color.b)} / 0.99)`;
}

const isShadowRoot = (node: Node): node is ShadowRoot =>
  typeof ShadowRoot !== "undefined" && node instanceof ShadowRoot;

/** The element a node draws in: itself, its parent, or a shadow root's host. */
function elementOf(node: Node | null): Element | null {
  for (let at = node; at; at = at.parentNode ?? (isShadowRoot(at) ? at.host : null)) {
    if (at.nodeType === 1) return at as Element;
  }
  return null;
}

/** The parent element across a shadow root boundary. */
function parentOf(element: Element): Element | null {
  if (element.parentElement) return element.parentElement;
  const root = element.parentNode;
  return root && isShadowRoot(root) ? root.host : null;
}

/** The layers of a background: its color, then the solid stops of any gradient layer over it (a
 * card that lays its tint as `linear-gradient(X, X)`). Top first. */
function backgroundLayers(style: CSSStyleDeclaration): RGBA[] {
  const layers: RGBA[] = [];
  const image = style.backgroundImage;
  if (image && image !== "none") {
    for (const layer of image.split(/,(?![^(]*\))(?=\s*(?:linear|radial|conic|url|none))/)) {
      if (!/^\s*linear-gradient/.test(layer)) continue;
      const stops = [...layer.matchAll(/(?:rgba?|color)\([^()]*\)/g)].map((match) => parseComputedColor(match[0]));
      // Only a solid layer (every stop the same) is a surface; a sheen or fade is not.
      if (stops.length && stops.every((stop) => stop && JSON.stringify(stop) === JSON.stringify(stops[0])))
        layers.push(stops[0]!);
    }
  }
  const color = parseComputedColor(style.backgroundColor);
  if (color) layers.push(color);
  return layers;
}

/** Surfaces already read in one pass, per element (ancestors shared by many matches read once). */
export type SurfaceMemo = Map<Element, RGB>;

/** The page canvas under every background: black in a dark page, else white. */
function canvasOf(element: Element): RGB {
  const view = element.ownerDocument.defaultView;
  const scheme = view?.getComputedStyle(element.ownerDocument.documentElement).colorScheme ?? "";
  const dark =
    scheme.includes("dark") &&
    (!scheme.includes("light") || view?.matchMedia?.("(prefers-color-scheme: dark)").matches);
  return dark ? BLACK : WHITE;
}

/**
 * The opaque color behind `node`: every background from it up to the page's root, composited, over
 * the page canvas. Reads one computed style per ancestor, so it costs the depth of the tree, never
 * its size; `memo` shares the ancestors' answers across one pass.
 */
export function surfaceUnder(node: Node | null, memo?: SurfaceMemo): RGB {
  const element = elementOf(node);
  if (!element) return WHITE;
  const known = memo?.get(element);
  if (known) return known;
  const view = element.ownerDocument.defaultView;
  const layers = view ? backgroundLayers(view.getComputedStyle(element)) : [];
  const firstOpaque = layers.findIndex((layer) => layer.a >= 0.999);
  const parent = parentOf(element);
  let color: RGB = firstOpaque >= 0 ? WHITE : parent ? surfaceUnder(parent, memo) : canvasOf(element);
  // From the bottom layer up; anything under the first opaque layer is covered.
  const visible = firstOpaque >= 0 ? layers.slice(0, firstOpaque + 1) : layers;
  for (let index = visible.length - 1; index >= 0; index -= 1) color = over(visible[index]!, color);
  memo?.set(element, color);
  return color;
}

/** The text color `node` draws in, over its surface. */
export function inkOf(node: Node | null, surface: RGB): RGB {
  const element = elementOf(node);
  const view = element?.ownerDocument.defaultView;
  const color = element && view ? parseComputedColor(view.getComputedStyle(element).color) : null;
  return color ? over(color, surface) : readableInk(surface);
}

const probes = new WeakMap<Document, HTMLElement>();

/**
 * A CSS color expression resolved to its computed color. Through one hidden probe per document,
 * placed once outside the body, so a read never adds or removes nodes (no observer of the page
 * sees it) on every selection change or Find paint.
 */
export function resolveCssColor(doc: Document, expression: string): RGBA | null {
  const view = doc.defaultView;
  if (!view) return null;
  let probe = probes.get(doc);
  if (!probe?.isConnected) {
    probe = doc.createElement("span");
    probe.setAttribute("aria-hidden", "true");
    probe.dataset.cmuxColorProbe = "";
    probe.style.cssText = "position:absolute;width:0;height:0;overflow:hidden;visibility:hidden;pointer-events:none";
    doc.documentElement.append(probe);
    probes.set(doc, probe);
  }
  probe.style.color = "";
  probe.style.color = expression;
  if (!probe.style.color) return null;
  return parseComputedColor(view.getComputedStyle(probe).color);
}
