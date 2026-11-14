// Find's highlights drawn to the surface under each match (HIGHLIGHT-CONTRAST, highlightContrast.ts):
// one shared painter for Find in Chat, the diff and code views and the Markdown page. The matches
// are grouped by the fill they get on their surface (a bubble, a card, a code block, the page), and
// each group is a CSS custom highlight of its own with a rule for its colors, in one stylesheet per
// document (and per shadow root that draws matches). A page has a handful of surfaces, so a paint
// makes a handful of highlights however many matches it draws. The current match takes the strong
// fill and its own text color, the others a softer one that keeps the text's color. A page keeps
// its own two highlights (every match, and the current one) registered for what reads them (the
// transcript finds its current match there); their stylesheet rules are only the fallback where
// this painter cannot run, and its groups draw over them (`priority`).
import {
  fitHighlight,
  highlightCss,
  HIGHLIGHT_FLOORS,
  inkOf,
  resolveCssColor,
  surfaceUnder,
  type HighlightFloor,
  type SurfaceMemo,
} from "./highlightContrast";
import type { RGBA } from "../backdrop";

/** The theme colors a page's Find starts from: CSS color expressions (custom properties allowed). */
export type FindColors = {
  /** The other matches' fill (a soft tint of the highlight). */
  match: string;
  /** The current match's fill. */
  current: string;
  /** The current match's text color. */
  currentInk: string;
};

type HighlightRegistry = { set(name: string, value: unknown): void; delete(name: string): void };
type HighlightCtor = new (...ranges: Range[]) => { priority: number };
type StyledRoot = DocumentOrShadowRoot & { adoptedStyleSheets: CSSStyleSheet[] };

function registry(): HighlightRegistry | undefined {
  return (globalThis.CSS as unknown as { highlights?: HighlightRegistry } | undefined)?.highlights;
}

function highlightCtor(): HighlightCtor | undefined {
  return (globalThis as unknown as { Highlight?: HighlightCtor }).Highlight;
}

/** The highlight names a painter last set, per base name, so the next paint and a clear remove them. */
const painted = new Map<string, string[]>();
/** One stylesheet per base name: its groups' rules, adopted wherever its matches draw. */
const sheets = new Map<string, { sheet: CSSStyleSheet | null; css: string; roots: Set<StyledRoot> }>();

function sheetFor(name: string) {
  let entry = sheets.get(name);
  if (!entry) {
    let sheet: CSSStyleSheet | null = null;
    try {
      sheet = typeof CSSStyleSheet === "function" ? new CSSStyleSheet() : null;
    } catch {
      // Constructable stylesheets unavailable: the matches stay unstyled; Find still counts them.
    }
    entry = { sheet, css: "", roots: new Set() };
    sheets.set(name, entry);
  }
  return entry;
}

function adopt(name: string, root: StyledRoot) {
  const entry = sheetFor(name);
  if (!entry.sheet || entry.roots.has(root)) return;
  try {
    root.adoptedStyleSheets = [...root.adoptedStyleSheets, entry.sheet];
    entry.roots.add(root);
  } catch {
    // A root that refuses adoption keeps its matches unstyled.
  }
}

/** Each painter's last paint, replayed when the theme changes: the fills are fit to the surfaces
 * and colors of the theme they were painted in, which `light-dark()` rules would have followed. */
type PaintArgs = Parameters<typeof paintAdaptiveFind>;
const lastPaint = new Map<string, PaintArgs>();
const themeWatched = new WeakSet<Document>();

/** Repaints every painter of `doc` once, on the next frame after the host's theme or the color
 * scheme changes. One listener pair per document; a paint with no painter left does nothing. */
function watchTheme(doc: Document): void {
  const view = doc.defaultView;
  if (!view || themeWatched.has(doc)) return;
  themeWatched.add(doc);
  let frame = 0;
  const repaint = () => {
    frame = 0;
    for (const args of lastPaint.values()) if (args[0] === doc) paintAdaptiveFind(...args);
  };
  const schedule = () => {
    if (!frame && lastPaint.size) frame = view.requestAnimationFrame(repaint);
  };
  view.addEventListener("cmux-theme", schedule);
  view.matchMedia?.("(prefers-color-scheme: dark)").addEventListener?.("change", schedule);
  // A page's own look on its root (the Markdown page's paper theme, Reading Settings) changes with no
  // host event. Only the theme attributes: the root's style carries the selection fill, set on every
  // selection change (adaptiveSelection.ts).
  new view.MutationObserver(schedule).observe(doc.documentElement, {
    attributes: true,
    attributeFilter: THEME_ATTRIBUTES,
  });
}

/** Root attributes that change a page's colors: its scheme class, the agent pane's theme and the
 * Markdown page's paper theme (settings.ts applyMarkdownLook). */
const THEME_ATTRIBUTES = ["class", "data-theme", "data-cmux-md-theme", "data-cmux-see-through"];

/** Removes every highlight `name`'s painter set. */
export function clearAdaptiveFind(name: string): void {
  const highlights = registry();
  for (const group of painted.get(name) ?? []) highlights?.delete(group);
  painted.delete(name);
  lastPaint.delete(name);
}

/** Drops `name`'s stylesheet from every root it was adopted into (a painter's dispose). */
export function releaseAdaptiveFind(name: string): void {
  clearAdaptiveFind(name);
  const entry = sheets.get(name);
  if (!entry) return;
  for (const root of entry.roots) root.adoptedStyleSheets = root.adoptedStyleSheets.filter((s) => s !== entry.sheet);
  sheets.delete(name);
}

/** Above a page's own two highlights (priority 0 and 1). */
const PRIORITY = 2;

/**
 * Paints `ranges` as Find's matches and `current` (the one the reader is on, its ranges) each fit to the
 * surface under it. `roots` are the shadow roots matches draw in (highlight rules do not cross a
 * shadow boundary); the document always gets the rules.
 */
export function paintAdaptiveFind(
  doc: Document,
  name: string,
  colors: FindColors,
  ranges: readonly Range[],
  current: readonly Range[],
  roots: readonly ShadowRoot[] = [],
  /** The floors to fit to; the shared ones unless a gallery compares others. */
  floors: { match: HighlightFloor; current: HighlightFloor } = {
    match: HIGHLIGHT_FLOORS.findMatch,
    current: HIGHLIGHT_FLOORS.findCurrent,
  },
): void {
  const highlights = registry();
  const Highlight = highlightCtor();
  if (!highlights || !Highlight) return;
  lastPaint.set(name, [doc, name, colors, ranges, current, roots, floors]);
  watchTheme(doc);
  const matchBase = resolveCssColor(doc, colors.match);
  const currentBase = resolveCssColor(doc, colors.current);
  const currentInk = resolveCssColor(doc, colors.currentInk);
  const memo: SurfaceMemo = new Map();
  const inks = new Map<Node, ReturnType<typeof inkOf>>();
  const inkOn = (node: Node, surface: ReturnType<typeof surfaceUnder>) => {
    const owner = node.parentNode ?? node;
    let ink = inks.get(owner);
    if (!ink) inks.set(owner, (ink = inkOf(node, surface)));
    return ink;
  };
  // Matches on one surface in one text color share one fit.
  const fits = new Map<string, string>();
  const groups = new Map<string, { rule: string; ranges: Range[]; priority: number }>();
  const add = (range: Range, base: RGBA | null, active: boolean) => {
    if (!base) return;
    const surface = surfaceUnder(range.startContainer, memo);
    const ink =
      active && currentInk
        ? { r: currentInk.r / 255, g: currentInk.g / 255, b: currentInk.b / 255 }
        : inkOn(range.startContainer, surface);
    const fitKey = `${active} ${highlightCss(surface)} ${highlightCss(ink)}`;
    let rule = fits.get(fitKey);
    if (rule === undefined) {
      const fit = fitHighlight(base, surface, ink, active ? floors.current : floors.match, { freeInk: active });
      const fill = highlightCss(fit.fill);
      // The other matches keep their text's own color; only the current one draws its own.
      rule = active ? `background-color: ${fill}; color: ${highlightCss(fit.ink)};` : `background-color: ${fill};`;
      fits.set(fitKey, rule);
    }
    const key = `${active ? "current" : "match"} ${rule}`;
    let group = groups.get(key);
    if (!group) groups.set(key, (group = { rule, ranges: [], priority: PRIORITY + (active ? 1 : 0) }));
    group.ranges.push(range);
  };
  const currentSet = new Set(current);
  for (const range of ranges) if (!currentSet.has(range)) add(range, matchBase, false);
  for (const range of current) add(range, currentBase, true);

  const names: string[] = [];
  let css = "";
  for (const group of groups.values()) {
    const groupName = `${name}-fit-${names.length}`;
    names.push(groupName);
    css += `::highlight(${groupName}) { ${group.rule} }\n`;
    const highlight = new Highlight(...group.ranges);
    highlight.priority = group.priority;
    highlights.set(groupName, highlight);
  }
  for (const stale of (painted.get(name) ?? []).slice(names.length)) highlights.delete(stale);
  painted.set(name, names);

  const entry = sheetFor(name);
  adopt(name, doc as unknown as StyledRoot);
  for (const root of roots) adopt(name, root as unknown as StyledRoot);
  if (entry.sheet && entry.css !== css) {
    entry.sheet.replaceSync(css);
    entry.css = css;
  }
}
