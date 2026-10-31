// Settings > Menus' tree edits (menuLayouts.ts) and pointer geometry (menuDrag.ts): a node moves to
// any index of any submenu, counted before the move; a submenu never into itself; a drop lands
// where the pointer is among the rows as the drag shows them, between any two rows at any depth.
import { expect, test } from "bun:test";
import { dropTarget, shifts, type RowBox } from "./menuDrag";
import { deleteGroup, destinations, move, step, type Folder } from "./menuLayouts";
import type { MenuLayout } from "./ops";

const layout: MenuLayout = {
  items: ["a", "b", { key: "folder:more", items: ["c", { key: "folder:options", items: ["d"] }] }, "e"],
  hidden: [],
};

test("a node moves to any index of any submenu, the old place still counted", () => {
  expect(move(layout, [0], [], 3).items).toEqual([
    "b",
    { key: "folder:more", items: ["c", { key: "folder:options", items: ["d"] }] },
    "a",
    "e",
  ]);
  expect(move(layout, [3], [2, 1], 0).items[2]).toEqual({
    key: "folder:more",
    items: ["c", { key: "folder:options", items: ["e", "d"] }],
  });
  expect(move(layout, [2, 1, 0], [], 0).items[0]).toBe("d");
  // Into itself or inside itself: nothing changes.
  expect(move(layout, [2], [2, 1], 0)).toBe(layout);
  expect(step(layout, [1], -1).items.slice(0, 2)).toEqual(["b", "a"]);
  expect(step(layout, [0], -1)).toBe(layout);
});

test("Move to… lists every submenu but the node's own and those inside it", () => {
  const title = (node: Folder) => node.key;
  expect(destinations(layout, [0], title).map((d) => d.trail.join(" › "))).toEqual([
    "",
    "folder:more",
    "folder:more › folder:options",
  ]);
  expect(destinations(layout, [2], title).map((d) => d.trail.join(" › "))).toEqual([""]);
});

test("deleting the person's submenu leaves its rows in its place", () => {
  const mine: MenuLayout = {
    items: ["a", { key: "group:x", title: "X", items: ["b", "c"] }, "d"],
    hidden: ["group:x"],
  };
  expect(deleteGroup(mine, [1])).toEqual({ items: ["a", "b", "c", "d"], hidden: [] });
});

// A top row, an open submenu with one row, and a closed submenu (four rows), 24 px apart.
const rows: RowBox[] = [
  { flat: 0, path: [0], depth: 0, top: 100, bottom: 124, folder: false, open: false, children: 0 },
  { flat: 1, path: [1], depth: 0, top: 124, bottom: 148, folder: true, open: true, children: 1 },
  { flat: 2, path: [1, 0], depth: 1, top: 148, bottom: 172, folder: false, open: false, children: 0 },
  { flat: 3, path: [2], depth: 0, top: 172, bottom: 196, folder: true, open: false, children: 4 },
];

test("a drop goes where the pointer is among the rows as the drag shows them", () => {
  // The closed submenu dragged up between the first two rows.
  expect(dropTarget(rows, [2], 24, 125, 0)).toEqual({ parent: [], index: 1, depth: 0, slot: 1 });
  // The first row lifted out, the rest move up a row: between the open submenu and its row is inside it.
  expect(dropTarget(rows, [0], 24, 120, 0)).toEqual({ parent: [1], index: 0, depth: 1, slot: 1 });
  // The middle of a closed submenu (now at 148–172): into it, at its end.
  expect(dropTarget(rows, [0], 24, 160, 0)).toEqual({ parent: [2], index: 4, depth: 1, slot: null, into: [2] });
  // Below every row: the top level's end.
  expect(dropTarget(rows, [0], 24, 400, 0)).toEqual({ parent: [], index: 3, depth: 0, slot: 3 });
  // Back where it was: no move.
  expect(dropTarget(rows, [0], 24, 110, 0)).toBeNull();
});

test("at a submenu's end the pointer's sideways travel picks in or out", () => {
  // Between the submenu's last row and the next top-level row (y 150, the block lifted out).
  expect(dropTarget(rows, [0], 24, 150, 0)).toEqual({ parent: [], index: 2, depth: 0, slot: 2 });
  expect(dropTarget(rows, [0], 24, 150, 18)).toEqual({ parent: [1], index: 1, depth: 1, slot: 2 });
  // A row of the submenu dragged a little left leaves it, after it.
  expect(dropTarget(rows, [1, 0], 24, 150, -18)).toEqual({ parent: [], index: 2, depth: 0, slot: 2 });
  // A submenu is never dropped inside itself: its rows are lifted out with it.
  for (const y of [110, 130, 140, 160, 400]) {
    const target = dropTarget(rows, [1], 48, y, 40);
    expect(target === null || !(target.parent[0] === 1 && target.parent.length > 0)).toBe(true);
  }
});

test("the rows below the lifted block move up into its place, and the rows from the gap down open it", () => {
  // The last row dragged to the top: every other row slides down one row.
  expect([...shifts(rows, 3, 3, 24, 0)]).toEqual([
    [0, 24],
    [1, 24],
    [2, 24],
  ]);
  // The first row dragged to the end: the rest slide up into its place.
  expect([...shifts(rows, 0, 0, 24, 3)]).toEqual([
    [1, -24],
    [2, -24],
    [3, -24],
  ]);
  // The first row dropped after the open submenu's row: only that submenu row moves up.
  expect([...shifts(rows, 0, 0, 24, 1)]).toEqual([[1, -24]]);
  // An open submenu (two drawn rows) dragged to the top.
  expect([...shifts(rows, 1, 2, 48, 0)]).toEqual([[0, 48]]);
  // Into a closed submenu: no gap, the rows below close up.
  expect([...shifts(rows, 0, 0, 24, null)]).toEqual([
    [1, -24],
    [2, -24],
    [3, -24],
  ]);
  expect(shifts(rows, 0, 0, 24, undefined).size).toBe(0);
});
