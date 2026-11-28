import { afterEach, expect, test } from "bun:test";
import { writeScrollBy, writeScrollTop } from "./scrollController";

const scope = globalThis as { __cmuxScrollTrace?: unknown };
afterEach(() => {
  delete scope.__cmuxScrollTrace;
});

/// A scroller that clamps its offset to [0, max] and rounds it to whole pixels, as WebKit does.
function scroller(max = 1000) {
  let top = 0;
  let reads = 0;
  return {
    get scrollTop() {
      reads += 1;
      return top;
    },
    set scrollTop(value: number) {
      top = Math.round(Math.max(0, Math.min(max, value)));
    },
    reads: () => reads,
  };
}

test("a write lands at once and reads nothing back when nobody traces", () => {
  const node = scroller();
  writeScrollTop(node, 120.4, "follow");
  expect(node.reads()).toBe(0);
  expect(node.scrollTop).toBe(120);
  writeScrollBy(node, -20, "lift");
  expect(node.scrollTop).toBe(100);
});

test("a trace names each write that moved the offset, with where the browser put it", () => {
  const trace: { writer: string; from: number; to: number }[] = [];
  scope.__cmuxScrollTrace = trace;
  const node = scroller(500);
  writeScrollTop(node, 900, "jump");
  writeScrollTop(node, 500, "follow");
  writeScrollBy(node, -40, "fold");
  expect(trace.map(({ writer, from, to }) => ({ writer, from, to }))).toEqual([
    { writer: "jump", from: 0, to: 500 },
    { writer: "fold", from: 500, to: 460 },
  ]);
});
