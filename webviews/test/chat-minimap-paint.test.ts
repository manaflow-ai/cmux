// The VS Code Minimap's painter (chatMinimap/paint.ts): the whole chat drawn into one canvas from the
// transcript's layout. A draw is bounded by the canvas's height, not by the number of rows: rows that
// land on the same device pixel line merge, and each kind is one path and one fill.
import { expect, test } from "bun:test";
import type { AcpmuxRow, ConversationLayout } from "../src/agent-session/acpmux/model";
import {
  firstChangedRow,
  minimapKind,
  minimapScale,
  minimapView,
  paintMinimap,
  MAX_SCALE,
  type MinimapContext,
} from "../src/agent-session/acpmux/chatMinimap/paint";

const row = (index: number, kind: string, text?: string): AcpmuxRow => ({
  id: `r${index}`,
  kind,
  text,
  version: 1,
  at: 1,
});
/// `count` turns: a prompt and a reply each, `height` px apiece.
function chat(count: number, height: number) {
  const rows = Array.from({ length: count * 2 }, (_, index) => row(index, index % 2 ? "assistant" : "user", "text"));
  const heights = Float64Array.from(rows, () => height);
  const tops = Float64Array.from(rows, (_, index) => index * height);
  const layout: ConversationLayout = { tops, heights, totalHeight: rows.length * height };
  return { rows, layout };
}
function recorder() {
  const calls = { rects: 0, fills: 0 };
  const none = () => {};
  const ctx = {
    ...{ setTransform: none, clearRect: none, beginPath: none, fillStyle: "", globalAlpha: 1 },
    rect: () => void (calls.rects += 1),
    fill: () => void (calls.fills += 1),
  } as unknown as MinimapContext;
  return { ctx, calls };
}
const colors = { prompt: "#00f", reply: "#fff", tool: "#888" };

test("each row kind has its place; rows that draw nothing are skipped", () => {
  expect(minimapKind(row(0, "user"))).toBe("prompt");
  expect(minimapKind(row(0, "assistant", "hi"))).toBe("reply");
  expect(minimapKind(row(0, "assistant"))).toBeUndefined();
  expect(minimapKind(row(0, "activity"))).toBe("tool");
  expect(minimapKind(row(0, "date"))).toBeUndefined();
});

test("a short chat draws at 1/8 from the top; a long one fits the track", () => {
  expect(minimapScale(1000, 600)).toBe(MAX_SCALE);
  expect(minimapScale(100_000, 600)).toBeCloseTo(600 / (100_000 + 16), 8);
  const view = minimapView(50_000, 800, minimapScale(100_000, 600), 600);
  expect(view.height).toBeGreaterThanOrEqual(14);
  expect(view.top + view.height).toBeLessThanOrEqual(600);
});

test("a 20,000-row chat draws about as many rectangles as a 2,000-row one: bounded by the canvas", () => {
  const draw = (turns: number) => {
    const { rows, layout } = chat(turns, 60);
    const { ctx, calls } = recorder();
    const scale = minimapScale(layout.totalHeight, 600);
    paintMinimap(ctx, rows, layout, { width: 56, height: 600, dpr: 2, scale, colors });
    return calls;
  };
  const small = draw(1000);
  const large = draw(10_000);
  expect(small.fills).toBe(3);
  expect(large.fills).toBe(3);
  // At most one rectangle per kind per device pixel line (600 px at 2x).
  expect(large.rects).toBeLessThanOrEqual(3 * 1200);
  expect(large.rects).toBeLessThan(small.rects * 1.5);
});

test("firstChangedRow finds the first row whose place, height or kind moved", () => {
  const { rows, layout } = chat(10, 60);
  expect(firstChangedRow(rows, layout, { rows, layout })).toBe(rows.length);
  const heights = layout.heights.slice();
  heights[7] = 90;
  expect(firstChangedRow(rows, { ...layout, heights }, { rows, layout })).toBe(7);
  const longer = [...rows, row(99, "user", "next")];
  expect(firstChangedRow(longer, layout, { rows, layout })).toBe(rows.length);
});
