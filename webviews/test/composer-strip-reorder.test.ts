// Review (Codex): right to left the strip's order runs leftward, for a drag and for the arrows.
import { expect, test } from "bun:test";
import { dropIndex, moved } from "../src/agent-session/acpmux/composer/stripReorder";

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
