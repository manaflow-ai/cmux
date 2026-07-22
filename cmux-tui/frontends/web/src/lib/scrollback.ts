import type { ReadScrollbackResult, RenderRow } from "cmux/browser";

export interface ScrollbackRequest {
  start: number;
  count: number;
}

export interface ScrollbackWindow {
  total: number;
  pageSize: number;
  maxRows: number;
  rows: readonly RenderRow[];
}

export interface ScrollbackReconciliation {
  window: ScrollbackWindow;
  invalidated: boolean;
}

export function createScrollbackWindow(
  total: number,
  pageSize = 128,
  maxRows = 512,
): ScrollbackWindow {
  return {
    total: Math.max(0, total),
    pageSize: Math.max(1, pageSize),
    maxRows: Math.max(1, maxRows),
    rows: [],
  };
}

export function latestScrollbackRequest(window: ScrollbackWindow): ScrollbackRequest | null {
  if (window.total === 0 || window.rows.length > 0) return null;
  const start = Math.max(0, window.total - window.pageSize);
  return { start, count: window.total - start };
}

export function previousScrollbackRequest(window: ScrollbackWindow): ScrollbackRequest | null {
  if (window.rows.length === 0) return latestScrollbackRequest(window);
  const first = window.rows[0]!.row;
  if (first <= 0) return null;
  const start = Math.max(0, first - window.pageSize);
  return { start, count: first - start };
}

export function nextScrollbackRequest(window: ScrollbackWindow): ScrollbackRequest | null {
  if (window.rows.length === 0) return latestScrollbackRequest(window);
  const start = window.rows.at(-1)!.row + 1;
  if (start >= window.total) return null;
  return { start, count: Math.min(window.pageSize, window.total - start) };
}

export function reconcileScrollbackWindow(
  window: ScrollbackWindow,
  previousTotal: number,
  nextTotal: number,
  resized: boolean,
): ScrollbackReconciliation {
  const normalizedPrevious = Math.max(0, previousTotal);
  const normalizedNext = Math.max(0, nextTotal);
  const invalidated = resized || normalizedNext < normalizedPrevious;
  if (invalidated) {
    return {
      window: createScrollbackWindow(normalizedNext, window.pageSize, window.maxRows),
      invalidated: true,
    };
  }
  if (normalizedNext <= window.total) return { window, invalidated: false };
  return { window: { ...window, total: normalizedNext }, invalidated: false };
}

export function scrollbackAnchorDelta(
  previous: ScrollbackWindow,
  next: ScrollbackWindow,
  direction: "previous" | "next",
): number {
  if (previous.rows.length === 0 || next.rows.length === 0) return 0;
  const previousIndex = direction === "previous" ? 0 : previous.rows.length - 1;
  const anchor = previous.rows[previousIndex]!;
  const nextIndex = next.rows.findIndex((candidate) => candidate.row === anchor.row);
  return nextIndex < 0 ? 0 : nextIndex - previousIndex;
}

export function mergeScrollbackPage(
  window: ScrollbackWindow,
  page: ReadScrollbackResult,
): ScrollbackWindow {
  const existing = page.total < window.total ? [] : window.rows;
  const byIndex = new Map<number, RenderRow>();
  for (const row of existing) byIndex.set(row.row, row);
  for (const row of page.rows) {
    const absolute = page.start + row.row;
    if (!Number.isInteger(absolute) || absolute < 0 || absolute >= page.total) continue;
    byIndex.set(absolute, { row: absolute, runs: [...row.runs] });
  }

  let rows = [...byIndex.values()].sort((left, right) => left.row - right.row);
  if (rows.length > window.maxRows) {
    const previousFirst = existing[0]?.row;
    const prepended = previousFirst !== undefined && page.start < previousFirst;
    rows = prepended ? rows.slice(0, window.maxRows) : rows.slice(-window.maxRows);
  }

  return { ...window, total: page.total, rows };
}
