import { expect, test } from "bun:test";
import type { AcpmuxTimeBreakdown } from "../model";
import {
  hasUnknownCategoryTokens,
  normalizedTimeBreakdown,
  pageCount,
  timeSpanPage,
  turnTokenForSpan,
} from "./timeBreakdownModel";

const breakdown = (spans: AcpmuxTimeBreakdown["spans"]): AcpmuxTimeBreakdown => ({
  totalMs: 100,
  totalTokens: 4,
  tokensComplete: true,
  categories: [{ id: "run", wallMs: 100, tokens: 4 }],
  spans,
});

test("normalizes malformed journal rows and orders spans without mutating the source", () => {
  const source = breakdown([
    { turnSeq: 2, category: "run", startAt: 30, endAt: 40 },
    { turnSeq: 1, category: "read", startAt: 10, endAt: 20 },
    { turnSeq: 3, category: "broken", startAt: 50, endAt: Number.NaN },
    { turnSeq: 4, category: "broken", startAt: -1, endAt: 2 },
    null as never,
    "not a span" as never,
  ]);
  const normalized = normalizedTimeBreakdown(source);
  expect(normalized.spans.map((span) => span.turnSeq)).toEqual([1, 2]);
  expect(source.spans.slice(0, 4).map((span) => span.turnSeq)).toEqual([2, 1, 3, 4]);
});

test("retains only supported categories and bounds retained spans", () => {
  const source = breakdown([
    ...Array.from({ length: 600 }, (_, index) => ({
      turnSeq: index,
      category: "run",
      startAt: index,
      endAt: index + 1,
    })),
    { turnSeq: 601, category: "future", startAt: 601, endAt: 602 } as never,
  ]);
  const normalized = normalizedTimeBreakdown(source);
  expect(normalized.spans).toHaveLength(512);
  expect(normalized.spans[0]?.turnSeq).toBe(88);
});

test("pages recent spans in a bounded, stable window", () => {
  const spans = Array.from({ length: 49 }, (_, index) => ({
    turnSeq: index,
    category: "run",
    startAt: index,
    endAt: index + 1,
  }));
  expect(pageCount(spans.length)).toBe(3);
  expect(timeSpanPage(spans, 0, 24).map((span) => span.turnSeq)).toEqual(Array.from({ length: 24 }, (_, i) => i + 25));
  expect(timeSpanPage(spans, 2, 24).map((span) => span.turnSeq)).toEqual([0]);
  expect(timeSpanPage(spans, 99, 24).map((span) => span.turnSeq)).toEqual([0]);
});

test("category token totals remain unknown when any category attribution is missing", () => {
  const complete = breakdown([]);
  expect(hasUnknownCategoryTokens(complete)).toBe(false);
  expect(hasUnknownCategoryTokens({ ...complete, tokensComplete: false })).toBe(true);
  expect(hasUnknownCategoryTokens({ ...complete, categories: [{ id: "run", wallMs: 100 }] })).toBe(true);
});

test("whole-turn token usage is accepted independently of category attribution", () => {
  expect(turnTokenForSpan({ turnSeq: 1, category: "think", startAt: 0, endAt: 1, turnTokens: 9 })).toBe(9);
  expect(turnTokenForSpan({ turnSeq: 1, category: "think", startAt: 0, endAt: 1, turnTokens: -1 })).toBeUndefined();
});
