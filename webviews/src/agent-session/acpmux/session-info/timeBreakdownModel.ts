import type { AcpmuxTimeBreakdown, AcpmuxTimeCategory, AcpmuxTimeSpan } from "../model";

export const TIME_SPANS_PER_PAGE = 24;
export const MAX_RETAINED_SPANS = 512;
export const TIME_CATEGORIES = ["read", "edit", "run", "think", "person", "model"] as const;

/** Values safe for layout. Journal records can be partially written or from an older daemon. */
export function validTimeSpan(span: unknown): span is AcpmuxTimeSpan {
  if (!span || typeof span !== "object") return false;
  const value = span as AcpmuxTimeSpan;
  return (
    Number.isFinite(value.startAt) &&
    Number.isFinite(value.endAt) &&
    value.startAt >= 0 &&
    value.endAt >= value.startAt &&
    Number.isFinite(value.turnSeq) &&
    value.turnSeq >= 0 &&
    typeof value.category === "string" &&
    (TIME_CATEGORIES as readonly string[]).includes(value.category)
  );
}

export function validTimeCategory(category: unknown): category is AcpmuxTimeCategory {
  if (!category || typeof category !== "object") return false;
  const value = category as AcpmuxTimeCategory;
  return (
    typeof value.id === "string" &&
    (TIME_CATEGORIES as readonly string[]).includes(value.id) &&
    Number.isFinite(value.wallMs) &&
    value.wallMs > 0
  );
}

/** Sanitizes and orders untrusted daemon data without mutating the snapshot. */
export function normalizedTimeBreakdown(input: unknown): AcpmuxTimeBreakdown {
  const breakdown = input && typeof input === "object" ? (input as Partial<AcpmuxTimeBreakdown>) : {};
  const spans = (Array.isArray(breakdown.spans) ? breakdown.spans : [])
    .filter(validTimeSpan)
    .map((span) => ({
      ...span,
      ...(typeof span.turnId === "string" && span.turnId ? { turnId: span.turnId } : { turnId: undefined }),
      ...(Number.isFinite(span.tokens) && span.tokens! >= 0 ? { tokens: span.tokens } : { tokens: undefined }),
      ...(Number.isFinite(span.turnTokens) && span.turnTokens! >= 0
        ? { turnTokens: span.turnTokens }
        : { turnTokens: undefined }),
    }))
    .sort((a, b) => a.startAt - b.startAt || a.endAt - b.endAt || a.turnSeq - b.turnSeq);
  const categories = (Array.isArray(breakdown.categories) ? breakdown.categories : [])
    .filter(validTimeCategory)
    .map((category) => ({
      ...category,
      ...(Number.isFinite(category.tokens) && category.tokens! >= 0
        ? { tokens: category.tokens }
        : { tokens: undefined }),
    }));
  const retained = spans.length > MAX_RETAINED_SPANS ? spans.slice(-MAX_RETAINED_SPANS) : spans;
  const totalMs =
    typeof breakdown.totalMs === "number" && Number.isFinite(breakdown.totalMs) && breakdown.totalMs >= 0
      ? breakdown.totalMs
      : 0;
  const totalTokens =
    typeof breakdown.totalTokens === "number" && Number.isFinite(breakdown.totalTokens) && breakdown.totalTokens >= 0
      ? breakdown.totalTokens
      : undefined;
  return {
    ...breakdown,
    totalMs,
    totalTokens,
    tokensComplete: breakdown.tokensComplete === true,
    spans: retained,
    categories,
  };
}

export function pageCount(spanCount: number, pageSize = TIME_SPANS_PER_PAGE): number {
  return Math.max(1, Math.ceil(Math.max(0, spanCount) / Math.max(1, pageSize)));
}

/** Returns one bounded page, newest page first (page 0 is the most recent spans). */
export function timeSpanPage(
  spans: readonly AcpmuxTimeSpan[],
  page: number,
  pageSize = TIME_SPANS_PER_PAGE,
): AcpmuxTimeSpan[] {
  const size = Math.max(1, pageSize);
  const pages = pageCount(spans.length, size);
  const safePage = Math.min(Math.max(0, Math.floor(page)), pages - 1);
  const end = spans.length - safePage * size;
  return spans.slice(Math.max(0, end - size), end);
}

export function hasUnknownCategoryTokens(breakdown: AcpmuxTimeBreakdown): boolean {
  const categories = Array.isArray(breakdown.categories) ? breakdown.categories : [];
  return (
    !breakdown.tokensComplete ||
    categories.some((category) => validTimeCategory(category) && category.tokens === undefined)
  );
}

export function turnTokenForSpan(span: AcpmuxTimeSpan): number | undefined {
  return Number.isFinite(span.turnTokens) && span.turnTokens! >= 0 ? span.turnTokens : undefined;
}
