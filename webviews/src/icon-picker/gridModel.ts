// The picker grid's layout as plain data: sections cut into header rows and item rows of
// `columns` cells, row offsets for virtualization (only rows in the viewport mount), and
// keyboard moves over the flat item order. No DOM here, so the window math and the moves are
// unit tested and cost O(log rows) per scroll frame.

export interface GridSection<T> {
  readonly id: string;
  readonly title: string;
  readonly items: readonly T[];
}

export type GridRow<T> =
  | { readonly kind: "header"; readonly key: string; readonly title: string; readonly top: number }
  | {
      readonly kind: "items";
      readonly key: string;
      /** Index in `GridLayout.items` of the first cell. */
      readonly first: number;
      readonly items: readonly T[];
      readonly top: number;
    };

export interface GridMetrics {
  readonly cell: number;
  readonly header: number;
}

export interface GridLayout<T> {
  readonly columns: number;
  readonly rows: readonly GridRow<T>[];
  /** Every item in display order (recents, then sections). */
  readonly items: readonly T[];
  /** For each item, the index of its row. */
  readonly rowOfItem: readonly number[];
  readonly height: number;
  readonly metrics: GridMetrics;
}

export function layoutGrid<T>(
  sections: readonly GridSection<T>[],
  columns: number,
  metrics: GridMetrics,
): GridLayout<T> {
  const cols = Math.max(1, Math.floor(columns));
  const rows: GridRow<T>[] = [];
  const items: T[] = [];
  const rowOfItem: number[] = [];
  let top = 0;
  for (const section of sections) {
    if (section.items.length === 0) continue;
    if (section.title) {
      rows.push({ kind: "header", key: `h:${section.id}`, title: section.title, top });
      top += metrics.header;
    }
    for (let start = 0; start < section.items.length; start += cols) {
      const slice = section.items.slice(start, start + cols);
      for (let i = 0; i < slice.length; i++) rowOfItem.push(rows.length);
      rows.push({ kind: "items", key: `r:${section.id}:${start}`, first: items.length, items: slice, top });
      items.push(...slice);
      top += metrics.cell;
    }
  }
  return { columns: cols, rows, items, rowOfItem, height: top, metrics };
}

function rowHeight<T>(layout: GridLayout<T>, row: GridRow<T>): number {
  return row.kind === "header" ? layout.metrics.header : layout.metrics.cell;
}

/** The first row whose bottom is below `y` (binary search over row tops). */
export function rowAt<T>(layout: GridLayout<T>, y: number): number {
  let lo = 0;
  let hi = layout.rows.length - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    const row = layout.rows[mid];
    if (row.top + rowHeight(layout, row) <= y) lo = mid + 1;
    else hi = mid;
  }
  return Math.max(0, lo);
}

/** Rows to mount for a viewport, with `overscan` extra rows on each side. */
export function visibleRows<T>(
  layout: GridLayout<T>,
  scrollTop: number,
  viewport: number,
  overscan = 4,
): { start: number; end: number } {
  if (layout.rows.length === 0) return { start: 0, end: 0 };
  const start = Math.max(0, rowAt(layout, scrollTop) - overscan);
  const end = Math.min(layout.rows.length, rowAt(layout, scrollTop + viewport) + 1 + overscan);
  return { start, end };
}

export type GridMove = "left" | "right" | "up" | "down" | "pageUp" | "pageDown" | "home" | "end";

/** The item index after a keyboard move from `current` (-1 when nothing is active). */
export function moveActive<T>(layout: GridLayout<T>, current: number, move: GridMove, pageRows = 6): number {
  const count = layout.items.length;
  if (count === 0) return -1;
  if (current < 0 || current >= count) return 0;
  switch (move) {
    case "left":
      return Math.max(0, current - 1);
    case "right":
      return Math.min(count - 1, current + 1);
    case "home":
      return 0;
    case "end":
      return count - 1;
    default: {
      const steps = move === "pageUp" || move === "pageDown" ? pageRows : 1;
      const dir = move === "up" || move === "pageUp" ? -1 : 1;
      return verticalMove(layout, current, dir, steps);
    }
  }
}

function verticalMove<T>(layout: GridLayout<T>, current: number, dir: number, steps: number): number {
  const fromRow = layout.rows[layout.rowOfItem[current]];
  if (fromRow.kind !== "items") return current;
  const column = current - fromRow.first;
  let rowIndex = layout.rowOfItem[current];
  let target = current;
  for (let moved = 0; moved < steps;) {
    rowIndex += dir;
    if (rowIndex < 0 || rowIndex >= layout.rows.length) break;
    const row = layout.rows[rowIndex];
    if (row.kind !== "items") continue;
    target = row.first + Math.min(column, row.items.length - 1);
    moved++;
  }
  return target;
}

/** The scrollTop that brings `item`'s row fully into view, or null when it is visible. */
export function scrollToReveal<T>(
  layout: GridLayout<T>,
  item: number,
  scrollTop: number,
  viewport: number,
): number | null {
  const rowIndex = layout.rowOfItem[item];
  if (rowIndex === undefined) return null;
  const row = layout.rows[rowIndex];
  // Keep the section header above the first row visible.
  const previous = layout.rows[rowIndex - 1];
  const top = previous?.kind === "header" ? previous.top : row.top;
  const bottom = row.top + layout.metrics.cell;
  if (top < scrollTop) return top;
  if (bottom > scrollTop + viewport) return bottom - viewport;
  return null;
}
