import type { FindMatch } from "./model";

export const FIND_HIGHLIGHT_NAME = "cmux-find-match";
export const FIND_ACTIVE_HIGHLIGHT_NAME = "cmux-find-active";

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
  return typeof CSS !== "undefined" && "highlights" in CSS;
}

function clearHighlights(): void {
  if (!supportsFindHighlights()) {
    return;
  }
  CSS.highlights.delete(FIND_HIGHLIGHT_NAME);
  CSS.highlights.delete(FIND_ACTIVE_HIGHLIGHT_NAME);
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
  snapshot: FindPaintSnapshot,
): Element | null {
  const active = snapshot.active;
  if (active == null) {
    return null;
  }
  const candidates = Array.from(
    container.querySelectorAll(`[data-line-type][data-column-number="${active.lineNumber}"]`),
  ).filter((row) => rowMatchesSide(row, active.side));
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

/**
 * Paints find highlights over the currently RENDERED rows using the CSS
 * Custom Highlight API. The code view virtualizes rows, so this runs on
 * every scroll/DOM change; match COUNTING is model-side (`collectFindMatches`)
 * and never depends on what happens to be rendered. Highlight ranges are not
 * DOM mutations, so painting never re-triggers the mutation observer.
 */
function paint(container: HTMLElement, snapshot: FindPaintSnapshot): void {
  if (!supportsFindHighlights()) {
    return;
  }
  if (snapshot.query === "") {
    clearHighlights();
    return;
  }
  const matchRanges: Range[] = [];
  const activeRanges: Range[] = [];
  const activeRow = findActiveRow(container, snapshot);
  const rows = container.querySelectorAll("[data-line-type][data-column-number]");
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
  CSS.highlights.set(FIND_HIGHLIGHT_NAME, new Highlight(...matchRanges));
  const activeHighlight = new Highlight(...activeRanges);
  activeHighlight.priority = 1;
  CSS.highlights.set(FIND_ACTIVE_HIGHLIGHT_NAME, activeHighlight);
}

/**
 * Installs the paint loop: repaints on scroll and on virtualizer row churn,
 * coalesced to one paint per animation frame. Call `repaint()` after query,
 * navigation, or match changes; `dispose()` removes listeners and clears
 * all highlights.
 */
export function installFindHighlightPainter(options: PainterOptions): FindHighlightPainter {
  const { container, getSnapshot } = options;
  let frame: number | null = null;
  let disposed = false;

  const paintNow = () => {
    frame = null;
    if (!disposed) {
      paint(container, getSnapshot());
    }
  };
  const schedule = () => {
    if (frame == null && !disposed) {
      frame = requestAnimationFrame(paintNow);
    }
  };

  container.addEventListener("scroll", schedule, { passive: true });
  const observer = new MutationObserver(schedule);
  observer.observe(container, { childList: true, subtree: true, characterData: true });

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
