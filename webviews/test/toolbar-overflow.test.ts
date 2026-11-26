import { expect, test } from "bun:test";
import { resolveToolbarOverflow } from "../src/toolbar-overflow";

// Only ACCESSORY icon controls overflow into the "..." menu now. The source
// select, repo select, and Base picker are always rendered in the bar (a native
// <select> has no menu equivalent, so the repo select is never dropped). Items
// are HIGH priority first; the last is the first to overflow.
const items = [
  { id: "files-toggle" as const, width: 28 },
  { id: "layout-toggle" as const, width: 28 },
  { id: "external-link" as const, width: 28 },
];

test("keeps everything when the budget fits all items", () => {
  const result = resolveToolbarOverflow({ available: 600, reserved: 308, items });
  expect(result.visible).toEqual(["files-toggle", "layout-toggle", "external-link"]);
  expect(result.overflow).toEqual([]);
});

test("drops only the lowest-priority item when just one must go", () => {
  // budget = 370 - 308 = 62; files+layout = 56 fits, +external = 84 does not, so
  // external (lowest priority) is the only one to overflow.
  const result = resolveToolbarOverflow({ available: 370, reserved: 308, items });
  expect(result.visible).toEqual(["files-toggle", "layout-toggle"]);
  expect(result.overflow).toEqual(["external-link"]);
});

test("overflow is always a priority suffix (no reordering)", () => {
  // A narrow budget that fits files but not layout: layout AND the lower-priority
  // external must both overflow, never just external.
  // budget = 342 - 308 = 34; files(28) fits, +layout(28)=56 does not.
  const result = resolveToolbarOverflow({ available: 342, reserved: 308, items });
  expect(result.visible).toEqual(["files-toggle"]);
  expect(result.overflow).toEqual(["layout-toggle", "external-link"]);
});

test("everything overflows at extreme narrow widths", () => {
  const result = resolveToolbarOverflow({ available: 200, reserved: 308, items });
  expect(result.visible).toEqual([]);
  expect(result.overflow).toEqual(["files-toggle", "layout-toggle", "external-link"]);
});

test("non-finite width overflows everything rather than throwing", () => {
  const result = resolveToolbarOverflow({ available: Number.NaN, reserved: 308, items });
  expect(result.visible).toEqual([]);
  expect(result.overflow.length).toBe(items.length);
});

test("empty item list yields empty result", () => {
  expect(resolveToolbarOverflow({ available: 500, reserved: 100, items: [] })).toEqual({
    visible: [],
    overflow: [],
  });
});
