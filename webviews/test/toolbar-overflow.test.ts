import { expect, test } from "bun:test";
import { resolveToolbarOverflow } from "../src/toolbar-overflow";

// Items HIGH priority first; last is the first to overflow.
const items = [
  { id: "repo-select" as const, width: 110 },
  { id: "files-toggle" as const, width: 28 },
  { id: "layout-toggle" as const, width: 28 },
  { id: "external-link" as const, width: 28 },
];

test("keeps everything when the budget fits all items", () => {
  const result = resolveToolbarOverflow({ available: 600, reserved: 248, items });
  expect(result.visible).toEqual(["repo-select", "files-toggle", "layout-toggle", "external-link"]);
  expect(result.overflow).toEqual([]);
});

test("drops only the lowest-priority item when just one must go", () => {
  // budget = 418 - 248 = 170; repo+files+layout = 166 fits, +external = 194 does
  // not, so external (lowest priority) is the only one to overflow.
  const result = resolveToolbarOverflow({ available: 418, reserved: 248, items });
  expect(result.visible).toEqual(["repo-select", "files-toggle", "layout-toggle"]);
  expect(result.overflow).toEqual(["external-link"]);
});

test("overflow is always a priority suffix (no reordering)", () => {
  // A narrow budget that fits repo + files but not layout: layout AND the
  // lower-priority external must both overflow, never just external.
  // budget = 412 - 248 = 164; repo(110)+files(28)=138 fits, +layout(28)=166 does not.
  const result = resolveToolbarOverflow({ available: 412, reserved: 248, items });
  expect(result.visible).toEqual(["repo-select", "files-toggle"]);
  expect(result.overflow).toEqual(["layout-toggle", "external-link"]);
});

test("repo-select is the last optional control to drop", () => {
  // budget only fits the repo select.
  const result = resolveToolbarOverflow({ available: 360, reserved: 248, items });
  expect(result.visible).toEqual(["repo-select"]);
  expect(result.overflow).toEqual(["files-toggle", "layout-toggle", "external-link"]);
});

test("everything overflows at extreme narrow widths", () => {
  const result = resolveToolbarOverflow({ available: 200, reserved: 248, items });
  expect(result.visible).toEqual([]);
  expect(result.overflow).toEqual(["repo-select", "files-toggle", "layout-toggle", "external-link"]);
});

test("a zero-width item (absent repo select) still fits and does not reserve space", () => {
  const withoutRepo = [{ id: "repo-select" as const, width: 0 }, ...items.slice(1)];
  const result = resolveToolbarOverflow({ available: 340, reserved: 248, items: withoutRepo });
  expect(result.visible).toContain("repo-select");
  expect(result.visible).toContain("files-toggle");
});

test("non-finite width overflows everything rather than throwing", () => {
  const result = resolveToolbarOverflow({ available: Number.NaN, reserved: 248, items });
  expect(result.visible).toEqual([]);
  expect(result.overflow.length).toBe(items.length);
});

test("empty item list yields empty result", () => {
  expect(resolveToolbarOverflow({ available: 500, reserved: 100, items: [] })).toEqual({
    visible: [],
    overflow: [],
  });
});
