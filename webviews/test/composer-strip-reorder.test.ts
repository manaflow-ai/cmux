// Review (Codex): right to left the strip's order runs leftward, for a drag and for the arrows.
import { expect, test } from "bun:test";
import { dropIndex, followOffset, moved, slides } from "../src/agent-session/acpmux/composer/stripReorder";

test("a drop lands before the first chip whose center it has not passed, left to right", () => {
  // Chips centered at 100, 200, 300 (the dragged one left out).
  expect(dropIndex(50, [100, 200, 300])).toBe(0);
  expect(dropIndex(150, [100, 200, 300])).toBe(1);
  expect(dropIndex(350, [100, 200, 300])).toBe(3);
});

test("right to left the same drop counts from the right", () => {
  // The strip's order is right to left: its first chip is centered at 300.
  expect(dropIndex(350, [300, 200, 100], true)).toBe(0);
  expect(dropIndex(250, [300, 200, 100], true)).toBe(1);
  expect(dropIndex(50, [300, 200, 100], true)).toBe(3);
});

test("moved puts an id at its new index", () => {
  expect(moved(["a", "b", "c"], "a", 2)).toEqual(["b", "c", "a"]);
  expect(moved(["a", "b", "c"], "c", 0)).toEqual(["c", "a", "b"]);
});

// Leo, 2026-10-26: "there's no click-and-drag animation or whatever. Like, it has to just look like a
// drag-and-drop". The dragged chip rides the pointer; the chips it passes slide.
test("the dragged chip stays under the pointer where it was grabbed, inside the strip", () => {
  // Grabbed 10px from its left edge; its slot starts at 100; the strip runs 0..400; 80px wide.
  expect(followOffset(150, 10, 100, 80, 0, 400)).toBe(40);
  expect(followOffset(5, 10, 100, 80, 0, 400)).toBe(-100);
  expect(followOffset(500, 10, 100, 80, 0, 400)).toBe(220);
});

test("a re-laid strip slides each chip that moved from its old slot, never the dragged one", () => {
  const before = new Map([
    ["a", 0],
    ["b", 90],
    ["c", 180],
  ]);
  const after = new Map([
    ["b", 0],
    ["a", 90],
    ["c", 180],
  ]);
  expect(slides(before, after, "a")).toEqual([{ id: "b", delta: 90 }]);
  expect(slides(before, after)).toEqual([
    { id: "b", delta: 90 },
    { id: "a", delta: -90 },
  ]);
});
