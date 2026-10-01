import { describe, expect, test } from "bun:test";
import type { Tokens } from "marked";
import { diffRows, layoutConversation, markdownBlocks, measuredText, visibleLayoutRange, visibleRowRange, type AcpmuxRow, type ConversationLayout } from "./model";

const row = (id: string, version: number): AcpmuxRow => ({ id, version, at: 0, kind: "assistant", text: id });

describe("acpmux row snapshots", () => {
  test("only changed content versions update", () => {
    const before = new Map([["a", row("a", 1)], ["b", row("b", 1)]]);
    expect(diffRows(before, [row("a", 1), row("b", 2), row("c", 1)])).toEqual({
      added: [row("c", 1)],
      updated: [row("b", 2)],
      removed: [],
    });
  });

  test("virtualizer keeps a bounded overscan window", () => {
    expect(visibleRowRange(5000, 12000, 720)).toEqual({ first: 117, last: 141 });
  });

  test("binary-searches exact typed-array tops", () => {
    const layout: ConversationLayout = { tops: new Float64Array([0, 30, 90, 150]), heights: new Float64Array([30, 60, 60, 40]), totalHeight: 190 };
    expect(visibleLayoutRange(layout, 91, 40, 0)).toEqual({ first: 2, last: 3 });
    expect(visibleLayoutRange(layout, 0, 20, 1)).toEqual({ first: 0, last: 2 });
  });
});

/// A user bubble (9px padding top and bottom, styles.css) rendered taller than its row, so the next
/// row's text ran under it.
test("a one-line user row leaves room for its bubble and the gap below it", () => {
  const user = { id: "u", version: 1, at: 0, kind: "user", text: "Question 1: how should the transcript handle item 1?" };
  const { heights } = layoutConversation([user], 760);
  const bubblePadding = 18;
  const line = 20;
  const gap = 16;
  expect(heights[0]).toBeGreaterThanOrEqual(bubblePadding + line + gap);
});

/// Every row below measures one row through the estimator and compares it with what the CSS draws.
const height = (kind: string, text: string, width: number) => layoutConversation([{ id: `${kind}-${width}-${text}`, version: 1, at: 0, kind, text }], width).heights[0]!;
const paragraph = "word ".repeat(120).trim();

/// The bubble is at most 78% of the row and its 12px side padding sits inside that, so its text
/// wraps at 0.78 * width - 24, well short of the row's own width.
test("a long user message wraps at the bubble's width", () => {
  expect(height("user", paragraph, 724)).toBeGreaterThanOrEqual(height("assistant", paragraph, 0.78 * 724 - 24) + 18);
});

/// A single newline starts a new block when the next line is a heading or a list, and blocks are
/// 8px apart (styles.css), so splitting on blank lines alone missed the gap and the extra line.
test("a heading or a list after a single newline is its own block", () => {
  const line = 20;
  const gap = 8;
  const rowGap = 16;
  expect(height("assistant", "## Title\nSome text", 724)).toBeGreaterThanOrEqual(rowGap + 2 * line + gap);
  expect(height("assistant", "Intro:\n- one\n- two", 724)).toBeGreaterThanOrEqual(rowGap + 3 * line + gap);
});

/// List items are indented 40px (the browser's list padding), so their text wraps sooner.
test("a list item wraps at the list's indented width", () => {
  expect(height("assistant", `- ${paragraph}`, 724)).toBeGreaterThanOrEqual(height("assistant", paragraph, 724 - 40));
});

/// The estimator measures what the page draws. Inline code draws in 11.5px monospace, no wider than the
/// prose font's digits, and a task item draws its checkbox's source text.
test("a block is measured as the text it renders", () => {
  const [code] = markdownBlocks("Call `fill()` now") as Tokens.Paragraph[];
  expect(measuredText(code!.tokens, code!.text)).toBe("Call 000000 now");
  const [list] = markdownBlocks("- [ ] ship it") as Tokens.List[];
  expect(measuredText(list!.items[0]!.tokens, list!.items[0]!.text)).toBe("[ ] ship it");
});
