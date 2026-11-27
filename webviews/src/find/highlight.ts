import type { FindMatch } from "./model";

export const FIND_HIGHLIGHT_NAME = "cmux-find-match";
export const FIND_ACTIVE_HIGHLIGHT_NAME = "cmux-find-active";

// ::highlight() pseudo styles are scoped per tree: rules in the outer
// document never reach shadow trees, and the code view renders every row
// inside `diffs-container` open shadow roots. The rules therefore live here
// and are adopted into the document AND into every shadow root that hosts
// rows (see ensureHighlightStyles).
const highlightCSS = `
::highlight(${FIND_HIGHLIGHT_NAME}) {
  background-color: light-dark(rgba(255, 199, 0, 0.42), rgba(255, 199, 0, 0.34));
}
::highlight(${FIND_ACTIVE_HIGHLIGHT_NAME}) {
  background-color: light-dark(#ff9632, #e8821e);
  color: #1a1208;
}
`;

/**
 * What the painter reads on every pass. `activeItemSpan` is the active
 * match's file span in scroll coordinates (from the virtualizer's item
 * offsets); it disambiguates equal line numbers rendered by other files.
 */
export type FindPaintSnapshot = {
  /** Lowercased query, or "" when find is closed/empty. */
  query: string;
  active: FindMatch | null;
  activeItemSpan: { top: number; bottom: number } | null;
};

type PainterOptions = {
  container: HTMLElement;
  getSnapshot: () => FindPaintSnapshot;
};

export type FindHighlightPainter = {
  repaint: () => void;
  dispose: () => void;
};

export function supportsFindHighlights(): boolean {
  return typeof CSS !== "undefined" && "highlights" in CSS && typeof Highlight === "function";
}

function clearHighlights(): void {
  if (!supportsFindHighlights()) {
    return;
  }
  CSS.highlights.delete(FIND_HIGHLIGHT_NAME);
  CSS.highlights.delete(FIND_ACTIVE_HIGHLIGHT_NAME);
}

/**
 * Every open shadow root under `root`, depth-first. The code view hosts rows
 * in (possibly nested) open shadow roots; only the rendered virtualization
 * window exists at any time, so the scan stays small.
 */
export function collectOpenShadowRoots(root: ParentNode, into: ShadowRoot[] = []): ShadowRoot[] {
  for (const element of root.querySelectorAll("*")) {
    const shadowRoot = element.shadowRoot;
    if (shadowRoot != null) {
      into.push(shadowRoot);
      collectOpenShadowRoots(shadowRoot, into);
    }
  }
  return into;
}

// Code-line cells. The code view renders each line as a code cell carrying
// `data-line` (its own side's 1-based line number; context cells also carry
// `data-alt-line` for the other side) next to a SEPARATE line-number cell
// that carries `data-column-number` — the selector must never match the
// number cells, whose text is just digits. `data-no-newline` marks the
// final-line-without-newline cell variant.
const rowSelector = "[data-line-type]:is([data-line], [data-no-newline])";

function collectRows(container: HTMLElement, shadowRoots: ShadowRoot[]): Element[] {
  const rows: Element[] = Array.from(container.querySelectorAll(rowSelector));
  for (const root of shadowRoots) {
    rows.push(...Array.from(root.querySelectorAll(rowSelector)));
  }
  return rows;
}

type RowText = {
  nodes: Text[];
  /** Cumulative start offset of each node's text within the row string. */
  offsets: number[];
  text: string;
};

// Skip gutters (line numbers) and comment annotations; highlight only code.
const excludedAncestorsSelector =
  "[data-gutter], [data-gutter-buffer], [data-line-annotation], [data-gutter-utility-slot]";

function collectRowText(row: Element): RowText {
  const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      const parent = node.parentElement;
      if (parent == null || parent.closest(excludedAncestorsSelector) != null) {
        return NodeFilter.FILTER_REJECT;
      }
      return NodeFilter.FILTER_ACCEPT;
    },
  });
  const nodes: Text[] = [];
  const offsets: number[] = [];
  let text = "";
  for (let node = walker.nextNode(); node != null; node = walker.nextNode()) {
    nodes.push(node as Text);
    offsets.push(text.length);
    text += node.textContent ?? "";
  }
  return { nodes, offsets, text };
}

/** Maps a [start, end) offset in the row string to a DOM Range. */
function rangeFor(row: RowText, start: number, end: number): Range | null {
  const locate = (offset: number, isEnd: boolean): { node: Text; offset: number } | null => {
    for (let i = row.nodes.length - 1; i >= 0; i -= 1) {
      const nodeStart = row.offsets[i];
      const nodeLength = row.nodes[i].textContent?.length ?? 0;
      const within = isEnd
        ? offset > nodeStart && offset <= nodeStart + nodeLength
        : offset >= nodeStart && offset < nodeStart + nodeLength;
      if (within) {
        return { node: row.nodes[i], offset: offset - nodeStart };
      }
    }
    return null;
  };
  const startLocation = locate(start, false);
  const endLocation = locate(end, true);
  if (startLocation == null || endLocation == null) {
    return null;
  }
  const range = document.createRange();
  range.setStart(startLocation.node, startLocation.offset);
  range.setEnd(endLocation.node, endLocation.offset);
  return range;
}

function rowMatchesSide(row: Element, side: FindMatch["side"]): boolean {
  const lineType = row.getAttribute("data-line-type") ?? "";
  const isDeletionRow = lineType.includes("deletion");
  return side === "deletions" ? isDeletionRow : !isDeletionRow;
}

/** The row's top in the scroll container's content coordinates. */
function rowScrollTop(row: Element, container: HTMLElement): number {
  const rowRect = row.getBoundingClientRect();
  const containerRect = container.getBoundingClientRect();
  return rowRect.top - containerRect.top + container.scrollTop;
}

function findActiveRow(
  container: HTMLElement,
  rows: Element[],
  snapshot: FindPaintSnapshot,
): Element | null {
  const active = snapshot.active;
  if (active == null) {
    return null;
  }
  const lineNumber = String(active.lineNumber);
  const candidates = rows.filter((row) =>
    (row.getAttribute("data-line") === lineNumber ||
      row.getAttribute("data-alt-line") === lineNumber) &&
    rowMatchesSide(row, active.side),
  );
  if (candidates.length === 0) {
    return null;
  }
  if (candidates.length === 1) {
    return candidates[0];
  }
  const span = snapshot.activeItemSpan;
  if (span != null) {
    const within = candidates.filter((row) => {
      const top = rowScrollTop(row, container);
      return top >= span.top - 1 && top < span.bottom + 1;
    });
    if (within.length >= 1) {
      return within[0];
    }
  }
  // Fall back to the candidate closest to the viewport center; navigation
  // just centered the active match, so this only misfires if two files
  // render the same line number at the same height.
  const viewportCenter = container.scrollTop + container.clientHeight / 2;
  let best: Element | null = null;
  let bestDistance = Number.POSITIVE_INFINITY;
  for (const row of candidates) {
    const distance = Math.abs(rowScrollTop(row, container) - viewportCenter);
    if (distance < bestDistance) {
      best = row;
      bestDistance = distance;
    }
  }
  return best;
}

export type FindPaintRanges = {
  matchRanges: Range[];
  activeRanges: Range[];
};

/**
 * Collects highlight ranges for every query occurrence in the currently
 * RENDERED rows (light DOM and open shadow roots). Pure DOM reads — the
 * registry/style side effects live in `paint`. Exported for tests.
 */
export function collectFindPaintRanges(
  container: HTMLElement,
  snapshot: FindPaintSnapshot,
  shadowRoots: ShadowRoot[] = collectOpenShadowRoots(container),
): FindPaintRanges {
  const matchRanges: Range[] = [];
  const activeRanges: Range[] = [];
  if (snapshot.query === "") {
    return { matchRanges, activeRanges };
  }
  const rows = collectRows(container, shadowRoots);
  const activeRow = findActiveRow(container, rows, snapshot);
  for (const row of rows) {
    const rowText = collectRowText(row);
    const haystack = rowText.text.toLowerCase();
    let from = 0;
    let occurrence = 0;
    for (;;) {
      const start = haystack.indexOf(snapshot.query, from);
      if (start === -1) {
        break;
      }
      const range = rangeFor(rowText, start, start + snapshot.query.length);
      if (range != null) {
        const isActive = row === activeRow && occurrence === snapshot.active?.occurrence;
        if (isActive) {
          activeRanges.push(range);
        } else {
          matchRanges.push(range);
        }
      }
      occurrence += 1;
      from = start + Math.max(snapshot.query.length, 1);
    }
  }
  return { matchRanges, activeRanges };
}

/**
 * Paints find highlights over the rendered rows using the CSS Custom
 * Highlight API. The code view virtualizes rows, so this runs on every
 * scroll/DOM change; match COUNTING is model-side (`collectFindMatches`)
 * and never depends on what happens to be rendered. Highlight ranges are
 * not DOM mutations, so painting never re-triggers the mutation observers.
 */
function paint(
  container: HTMLElement,
  snapshot: FindPaintSnapshot,
  shadowRoots: ShadowRoot[],
): void {
  if (!supportsFindHighlights()) {
    return;
  }
  if (snapshot.query === "") {
    clearHighlights();
    return;
  }
  const { matchRanges, activeRanges } = collectFindPaintRanges(container, snapshot, shadowRoots);
  CSS.highlights.set(FIND_HIGHLIGHT_NAME, new Highlight(...matchRanges));
  const activeHighlight = new Highlight(...activeRanges);
  activeHighlight.priority = 1;
  CSS.highlights.set(FIND_ACTIVE_HIGHLIGHT_NAME, activeHighlight);
}

/**
 * Installs the paint loop: repaints on scroll and on row churn in the light
 * DOM and in every open shadow root (the virtualizer's rows live in shadow
 * trees that a document-level observer cannot see), coalesced to one paint
 * per animation frame. Shadow roots also get the ::highlight styles adopted,
 * since outer-document rules do not apply inside them. Call `repaint()`
 * after query, navigation, or match changes; `dispose()` removes listeners
 * and clears all highlights.
 */
export function installFindHighlightPainter(options: PainterOptions): FindHighlightPainter {
  const { container, getSnapshot } = options;
  let frame: number | null = null;
  let disposed = false;
  let highlightSheet: CSSStyleSheet | null = null;
  const styledRoots = new WeakSet<DocumentOrShadowRoot>();
  const observedRoots = new WeakSet<Node>();

  const adoptStyles = (root: DocumentOrShadowRoot & { adoptedStyleSheets: CSSStyleSheet[] }) => {
    if (styledRoots.has(root) || typeof CSSStyleSheet !== "function") {
      return;
    }
    try {
      highlightSheet ??= (() => {
        const sheet = new CSSStyleSheet();
        sheet.replaceSync(highlightCSS);
        return sheet;
      })();
      root.adoptedStyleSheets = [...root.adoptedStyleSheets, highlightSheet];
      styledRoots.add(root);
    } catch {
      // Constructable stylesheets unavailable: highlights simply stay
      // unstyled; find still counts and navigates.
    }
  };

  const observer = new MutationObserver(() => schedule());

  const syncShadowRoots = (): ShadowRoot[] => {
    const shadowRoots = collectOpenShadowRoots(container);
    for (const root of shadowRoots) {
      adoptStyles(root as DocumentOrShadowRoot & { adoptedStyleSheets: CSSStyleSheet[] });
      if (!observedRoots.has(root)) {
        observer.observe(root, { childList: true, subtree: true, characterData: true });
        observedRoots.add(root);
      }
    }
    return shadowRoots;
  };

  const paintNow = () => {
    frame = null;
    if (disposed) {
      return;
    }
    // New files stream in as new shadow hosts; re-sync before painting so
    // their rows are styled, observed, and painted in the same pass.
    const shadowRoots = syncShadowRoots();
    paint(container, getSnapshot(), shadowRoots);
  };
  const schedule = () => {
    if (frame == null && !disposed) {
      frame = requestAnimationFrame(paintNow);
    }
  };

  adoptStyles(document as unknown as DocumentOrShadowRoot & { adoptedStyleSheets: CSSStyleSheet[] });
  container.addEventListener("scroll", schedule, { passive: true });
  observer.observe(container, { childList: true, subtree: true, characterData: true });
  syncShadowRoots();

  return {
    repaint: schedule,
    dispose() {
      disposed = true;
      if (frame != null) {
        cancelAnimationFrame(frame);
        frame = null;
      }
      container.removeEventListener("scroll", schedule);
      observer.disconnect();
      clearHighlights();
    },
  };
}
