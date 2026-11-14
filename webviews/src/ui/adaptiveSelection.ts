// The text selection fit to what it sits on (HIGHLIGHT-CONTRAST, highlightContrast.ts): the page's
// selection color (the Ghostty config's, `--cmux-selection-base`) is kept where it reads, and where it
// would barely differ from the surface under the selected text (a chat bubble, a card, a code block,
// glass) its lightness moves until it does, in `--cmux-selection-fill`, which every `::selection` rule
// reads first (desktop.css). Installed once per page by the desktop layer (pages/shared/desktop.ts).
//
// Cost: one read per selection change, coalesced to a frame: the computed styles of the two ends'
// ancestors, never the page. The property changes only when the fill does, so a drag across one
// surface restyles nothing.
import {
  fitHighlightOn,
  highlightCss,
  HIGHLIGHT_FLOORS,
  inkOf,
  resolveCssColor,
  surfaceUnder,
  webKitSelectionColor,
  type HighlightFloor,
  type SurfaceMemo,
} from "./highlightContrast";

/** What every `::selection` rule reads first: the fill fit to the selection's surface. */
export const SELECTION_FILL_PROPERTY = "--cmux-selection-fill";

/** The selection color a page starts from: its own (`--cmux-selection-base`, the Markdown page's
 * setting), else the Ghostty config's, else the accent's tint (desktop.css's fallback). */
export const SELECTION_BASE =
  "var(--cmux-selection-base, var(--cmux-text-selection, color-mix(in srgb, var(--cmux-accent, CanvasText) 28%, transparent)))";

const installed = new WeakSet<Document>();

/** macOS WebKit paints an opaque `::selection` blended with white (webKitSelectionColor). */
const isWebKit = (view: Window) =>
  /AppleWebKit/.test(view.navigator.userAgent) && !/Chrom/.test(view.navigator.userAgent);

/** Sets `--cmux-selection-fill` for the selection now in `doc`; leaves it while nothing is selected. */
export function updateSelectionFill(doc: Document, floor: HighlightFloor = HIGHLIGHT_FLOORS.selection): void {
  const view = doc.defaultView;
  const selection = doc.getSelection();
  if (!view || !selection) return;
  const root = doc.documentElement;
  // A field's selection (the composer, Find's field, the Markdown source) is not the document's: it
  // draws in the config's color, never in a fill fit to another surface earlier.
  const active = doc.activeElement;
  if (active && /^(INPUT|TEXTAREA)$/.test(active.tagName)) {
    root.style.removeProperty(SELECTION_FILL_PROPERTY);
    return;
  }
  if (selection.rangeCount === 0 || selection.isCollapsed) return;
  const resolved = resolveCssColor(doc, SELECTION_BASE);
  if (!resolved) {
    root.style.removeProperty(SELECTION_FILL_PROPERTY);
    return;
  }
  const base = isWebKit(view) ? webKitSelectionColor(resolved) : resolved;
  const memo: SurfaceMemo = new Map();
  const start = surfaceUnder(selection.anchorNode, memo);
  const end = surfaceUnder(selection.focusNode, memo);
  const fit = fitHighlightOn(base, [start, end], inkOf(selection.anchorNode, start), floor);
  const value = highlightCss(fit.fill);
  if (root.style.getPropertyValue(SELECTION_FILL_PROPERTY) !== value)
    root.style.setProperty(SELECTION_FILL_PROPERTY, value);
}

/** Keeps `doc`'s selection fill fit as the selection moves. Once per document. */
export function installAdaptiveSelection(doc: Document = document): void {
  const view = doc.defaultView;
  if (!view || installed.has(doc)) return;
  installed.add(doc);
  let frame = 0;
  const run = () => {
    frame = 0;
    updateSelectionFill(doc);
  };
  doc.addEventListener("selectionchange", () => {
    if (!frame) frame = view.requestAnimationFrame(run);
  });
  // A theme or color scheme change moves the surfaces and the base: refit a selection that stays.
  const schedule = () => {
    if (!frame) frame = view.requestAnimationFrame(run);
  };
  view.addEventListener("cmux-theme", schedule);
  view.matchMedia?.("(prefers-color-scheme: dark)").addEventListener?.("change", schedule);
}
