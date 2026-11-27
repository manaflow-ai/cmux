// The rim's drag, on Leo's 2026-11-22 report: "the "halfway point" was not the halfway from 5. it was
// halfway down if there was only one row ... the dragging isn't properly relative accurate to the
// cursor, and it's just jumpy all over the place and doesn't have satisfying snap alongs. i also am
// not sure if clicking on the resizing area itself should necessarily hide it."
import { expect, test } from "bun:test";
import { HAT_DETENT, HAT_STRETCH, hatDragEnd, hatDragHeight, type HatDragFrame } from "./trayResize";

// Three 28px lines, open at all three (84px), in a 1000px window.
const three: HatDragFrame = { start: 84, edges: [28, 56, 84], viewport: 1000 };

test("the rim stays under the cursor 1:1 between the lines, and settles on a line's edge near it", () => {
  for (const grown of [-10, -20, -40, -70]) {
    const raw = 84 + grown;
    const near = three.edges.some((edge) => Math.abs(edge - raw) <= HAT_DETENT);
    if (!near) expect(hatDragHeight(three, grown)).toBe(raw);
  }
  expect(hatDragHeight(three, -26)).toBe(56); // 58 is 2px from the second line's edge: it settles there
  expect(hatDragHeight(three, -42)).toBe(42); // halfway between edges: exactly where the cursor is
  expect(hatDragHeight(three, -84)).toBe(0);
  expect(hatDragHeight(three, -200)).toBe(0);
});

test("past the last line the rim gives a little and holds, and moves back at once on the way down", () => {
  const out = [10, 40, 200, 2000].map((grown) => hatDragHeight(three, grown));
  for (let i = 1; i < out.length; i++) expect(out[i]!).toBeGreaterThanOrEqual(out[i - 1]!);
  expect(out.at(-1)!).toBeLessThanOrEqual(84 + HAT_STRETCH);
  expect(out[0]!).toBeGreaterThan(84);
  // One px back down from far past the end moves the rim: no dead zone to drag back through.
  expect(hatDragHeight(three, 1) - 84).toBeLessThanOrEqual(1);
});

test("release lands on whole lines: more than half a line shown stays, less goes; under half the first folds", () => {
  expect(hatDragEnd(three, -10)).toEqual({ kind: "size", height: 84 }); // 74: the third line is mostly shown
  expect(hatDragEnd(three, -16)).toEqual({ kind: "size", height: 56 }); // 68: under half of it
  expect(hatDragEnd(three, -60)).toEqual({ kind: "size", height: 28 }); // 24: most of the first line
  expect(hatDragEnd(three, -70)).toEqual({ kind: "fold" }); // 14: half of one line, the fold's point
  expect(hatDragEnd(three, -71)).toEqual({ kind: "fold" });
  expect(hatDragEnd({ ...three, start: 140, edges: [28, 56, 84, 112, 140] }, -127)).toEqual({ kind: "fold" });
  // The fold point is half of ONE line, not half of the default five (70px).
  expect(hatDragEnd({ ...three, start: 140, edges: [28, 56, 84, 112, 140] }, -70)).toEqual({
    kind: "size",
    height: 56,
  });
});

test("a press that never moves past the slop does nothing, open or folded", () => {
  expect(hatDragEnd(three, 0)).toEqual({ kind: "rest" });
  expect(hatDragEnd(three, 2)).toEqual({ kind: "rest" });
  expect(hatDragEnd(three, -2)).toEqual({ kind: "rest" });
  expect(hatDragEnd({ ...three, start: 0 }, 1)).toEqual({ kind: "rest" });
});

test("from folded, a drag up opens to the lines the cursor reached; pulled past the end, the cap is where it went", () => {
  const folded = { ...three, start: 0 };
  expect(hatDragHeight(folded, 20)).toBe(20);
  expect(hatDragEnd(folded, 20)).toEqual({ kind: "size", height: 28 });
  expect(hatDragEnd(folded, 10)).toEqual({ kind: "fold" });
  expect(hatDragEnd(folded, 300)).toEqual({ kind: "size", height: 300 });
  expect(hatDragEnd(folded, 5000)).toEqual({ kind: "size", height: 700 });
});
