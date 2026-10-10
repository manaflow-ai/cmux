import { describe, expect, test } from "bun:test";
import {
  clipInset,
  effectiveArm,
  openness,
  relation,
  rowKeyframes,
  rowVisual,
  sampleTimes,
  startFolder,
  TREE_ARMS,
  travelFor,
} from "./treeMotion";

const h = 28;
// Folder A at the top of the list; its block is 5 rows; the row after it is 6 rows down.
const geometry = { path: "src/components/", height: 5 * h, travel: 5 * h, top: 0, rowHeight: h };
const following = { path: "src/lib/", top: 6 * h, height: h };
const child = { path: "src/components/Panel01.tsx", top: h, height: h };

describe("disclosure motion", () => {
  test("a toggle starts at the shown state and ends at the target", () => {
    const open = startFolder(undefined, { ...geometry, open: true }, TREE_ARMS.d, 1000);
    expect(openness(open, 1000)).toBe(0);
    expect(openness(open, 1000 + open.duration)).toBe(1);
    // The row after the block starts where it was (one row below the folder) and ends in place.
    expect(rowVisual(following, [open], TREE_ARMS.d, 1000).y).toBe(-5 * h);
    expect(rowVisual(following, [open], TREE_ARMS.d, 1000 + open.duration).y).toBe(0);
    // The child starts hidden under the folder row (a zero-height band) and ends whole.
    const start = rowVisual(child, [open], TREE_ARMS.d, 1000);
    const inset = clipInset(start, child.top, child.height)!;
    expect(inset.top + inset.bottom).toBeGreaterThanOrEqual(h);
    expect(clipInset(rowVisual(child, [open], TREE_ARMS.d, 1000 + open.duration), child.top, h)).toBeNull();
    // The chevron turns from closed (-90) to open (0).
    expect(rowVisual({ path: geometry.path, top: 0, height: h }, [open], TREE_ARMS.d, 1000).rotate).toBe(-90);
  });

  test("a second click reverses from the openness on screen, with no jump", () => {
    const open = startFolder(undefined, { ...geometry, open: true }, TREE_ARMS.b, 0);
    const mid = 60;
    const shownOpen = rowVisual(following, [open], TREE_ARMS.b, mid).y;
    const close = startFolder(open, { ...geometry, open: false }, TREE_ARMS.b, mid);
    expect(close.q0).toBeCloseTo(openness(open, mid), 6);
    // In the closed layout the same row sits 5 rows higher; its shown place is the same.
    const closedRow = { ...following, top: following.top - 5 * h };
    expect(closedRow.top + rowVisual(closedRow, [close], TREE_ARMS.b, mid).y).toBeCloseTo(following.top + shownOpen, 6);
    expect(rowVisual(closedRow, [close], TREE_ARMS.b, mid + close.duration).y).toBe(0);
  });

  test("arm f caps the travel at the room below the folder", () => {
    expect(travelFor(2000, 300, TREE_ARMS.f)).toBe(300);
    expect(travelFor(100, 300, TREE_ARMS.f)).toBe(100);
    expect(travelFor(2000, 300, TREE_ARMS.d)).toBe(2000);
  });

  test("folder paths compare whole segments", () => {
    const folder = { path: "src/a", top: 0 };
    expect(relation("src/ab/x.ts", 40, folder)).toBe("following");
    expect(relation("src/a/x.ts", 40, folder)).toBe("descendant");
    expect(relation("src/a", 0, folder)).toBe("self");
    expect(relation("readme.md", -28, folder)).toBe("before");
  });

  test("rows above the folder get no animation; the rows below get transforms only", () => {
    const open = startFolder(undefined, { ...geometry, top: 2 * h, open: true }, TREE_ARMS.c, 0);
    const times = sampleTimes([open], 0);
    expect(rowKeyframes({ path: "a.md", top: 0, height: h }, [open], TREE_ARMS.c, times)).toEqual({
      row: null,
      chevron: null,
    });
    const below = rowKeyframes({ path: "z/", top: 9 * h, height: h }, [open], TREE_ARMS.c, times).row!;
    expect(Object.keys(below[0]!).sort()).toEqual(["offset", "transform"]);
    expect(below[below.length - 1]!.transform).toBe("translate3d(0, 0px, 0)");
  });

  test("Reduce Motion snaps every moving arm; arm a stays instant", () => {
    expect(effectiveArm("d", true).kind).toBe("snap");
    expect(effectiveArm("e", true).tint).toBe(false);
    expect(effectiveArm("a", true).kind).toBe("none");
    expect(effectiveArm("d", false).kind).toBe("spring");
  });
});
