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
  streamingRow,
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
    setTransform: none,
    clearRect: none,
    beginPath: none,
    fillStyle: "",
    globalAlpha: 1,
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

/// A recorder that keeps every rectangle.
function rects() {
  const all: { x: number; y: number; w: number; h: number }[] = [];
  const none = () => {};
  const ctx = {
    setTransform: none,
    clearRect: none,
    beginPath: none,
    fill: none,
    fillStyle: "",
    globalAlpha: 1,
    rect: (x: number, y: number, w: number, h: number) => void all.push({ x, y, w, h }),
  } as unknown as MinimapContext;
  return { ctx, all };
}
/// Rows of the given ids and kinds, each `height` px, laid out top to bottom.
function laid(rows: AcpmuxRow[], height = 80): { rows: AcpmuxRow[]; layout: ConversationLayout } {
  const heights = Float64Array.from(rows, () => height);
  const tops = Float64Array.from(rows, (_, index) => index * height);
  return { rows, layout: { tops, heights, totalHeight: rows.length * height } };
}
const named = (id: string, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  text: "text",
  version: 1,
  at: 1,
  ...fields,
});
const options = { width: 56, height: 600, dpr: 2, scale: 1 / 8, colors };

test("a streaming reply is never painted: its place is the minimap's placeholder", () => {
  expect(minimapKind(named("a", "assistant", { streaming: true }))).toBeUndefined();
  const streaming = laid([named("u", "user"), named("a", "assistant", { streaming: true })], 400);
  const { ctx, all } = rects();
  paintMinimap(ctx, streaming.rows, streaming.layout, options);
  // Only the prompt: no reply line where the live reply is.
  expect(all.every((rect) => rect.x > 0)).toBe(true);
  expect(all.length).toBe(1);
});

test("a reply's lines keep their lengths when rows are inserted before it", () => {
  const replyLines = (rows: AcpmuxRow[]) => {
    const { layout } = laid(rows);
    // The reply always sits at the same place, so only its index moves.
    const at = rows.findIndex((row) => row.id === "reply");
    const tops = layout.tops.slice();
    tops[at] = 160;
    const { ctx, all } = rects();
    paintMinimap(ctx, rows, { ...layout, tops }, options);
    return all.filter((rect) => rect.x === 0).map((rect) => rect.w);
  };
  const before = replyLines([named("u1", "user"), named("reply", "assistant")]);
  const after = replyLines([named("u0", "user"), named("u1", "user"), named("reply", "assistant")]);
  expect(before.length).toBeGreaterThan(3);
  expect(after).toEqual(before);
});

test("firstChangedRow sees a same-shaped row replaced, and a reply that stops streaming", () => {
  const { rows, layout } = laid([named("u1", "user"), named("a1", "assistant"), named("u2", "user")]);
  const swapped = [rows[0]!, named("other", "assistant"), rows[2]!];
  expect(firstChangedRow(swapped, layout, { rows, layout })).toBe(1);
  const live = [rows[0]!, named("a1", "assistant", { streaming: true }), rows[2]!];
  expect(firstChangedRow(rows, layout, { rows: live, layout })).toBe(1);
  // The same row as a new object (a token): no change.
  const copy = [rows[0]!, { ...rows[1]! }, rows[2]!];
  expect(firstChangedRow(copy, layout, { rows, layout })).toBe(rows.length);
});

test("streamingRow finds the live reply however many rows follow it, reading only the changed rows", () => {
  const live = (text: string) => named("a", "assistant", { text, streaming: true });
  const queued = Array.from({ length: 30 }, (_, index) => named(`q${index}`, "user", { text: `Later ${index}` }));
  const first = [named("u", "user"), live("one"), ...queued];
  // No change to go on: every row is read once.
  const at = streamingRow(first, undefined, undefined);
  expect(at).toBe(1);
  // A token: the reply's object changes; the rows from it on are read again.
  const second = [first[0]!, live("one two"), ...queued];
  expect(streamingRow(second, { rows: first, index: at }, { base: first, rows: second, from: 1 })).toBe(1);
  // Only a queued prompt at the end changed: the rows before it are not read.
  const third = [...second.slice(0, -1), named("q29", "user", { text: "Later, edited" })];
  const reads = { count: 0 };
  const counted = new Proxy(third, {
    get(target, key, receiver) {
      if (typeof key === "string" && /^\d+$/.test(key)) reads.count += 1;
      return Reflect.get(target, key, receiver);
    },
  });
  expect(
    streamingRow(counted, { rows: second, index: 1 }, { base: second, rows: counted, from: third.length - 1 }),
  ).toBe(1);
  expect(reads.count).toBe(0);
  // The same rows again (a scroll frame): the same answer, nothing read.
  expect(streamingRow(counted, { rows: counted, index: 1 }, undefined)).toBe(1);
  expect(reads.count).toBe(0);
  // The reply ends.
  const ended = [first[0]!, named("a", "assistant", { text: "one two" }), ...queued];
  expect(streamingRow(ended, { rows: second, index: 1 }, { base: second, rows: ended, from: 1 })).toBe(-1);
});
