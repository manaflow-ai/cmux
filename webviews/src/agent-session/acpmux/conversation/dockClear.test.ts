// l10n-allow-file: test fixtures.
// The stack's clear rows (the "Needs your input" line over a pinned card) are holes in the
// transcript's mask (dockClear.ts). Leo, 2026-11-17: "this needs your input dismiss row erases
// things behind it". Before: the mask hid the transcript under the stack's whole height.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { dockClearSpans, dockClearStops } from "./dockClear";

function dock(rows: { clear?: boolean; top: number; height: number }[]) {
  const { document } = new JSDOM("<!doctype html><div id=dock></div>").window;
  const root = document.getElementById("dock")!;
  for (const { clear, top, height } of rows) {
    const row = document.createElement("div");
    if (clear) row.setAttribute("data-dock-clear", "");
    row.getBoundingClientRect = () => ({ top, bottom: top + height, height }) as DOMRect;
    root.append(row);
  }
  return root;
}

test("a clear row and the gap under it to its card are a hole, measured from the view's bottom", () => {
  // The view ends at 1000. The line at 700-728, its card at 732-832, the composer at 840-1000.
  const stack = dock([
    { clear: true, top: 700, height: 28 },
    { top: 732, height: 100 },
    { top: 840, height: 160 },
  ]);
  expect(dockClearSpans(stack, 1000)).toEqual([{ top: 300, bottom: 268 }]);
  expect(dockClearStops(dockClearSpans(stack, 1000))).toBe(
    ", transparent calc(100% - 300px), #000 calc(100% - 300px), #000 calc(100% - 268px), transparent calc(100% - 268px)",
  );
});

test("two pinned asks give two holes, top first; a stack with none adds nothing", () => {
  const stack = dock([
    { clear: true, top: 500, height: 28 },
    { top: 532, height: 100 },
    { clear: true, top: 640, height: 28 },
    { top: 672, height: 100 },
  ]);
  expect(dockClearSpans(stack, 1000).map((span) => span.top)).toEqual([500, 360]);
  expect(dockClearStops(dockClearSpans(dock([{ top: 840, height: 160 }]), 1000))).toBe("");
});

test("a clear row with no box (folded away) makes no hole", () => {
  expect(dockClearSpans(dock([{ clear: true, top: 0, height: 0 }]), 1000)).toEqual([]);
});
