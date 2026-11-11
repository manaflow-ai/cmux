// The bookmarks bar's pure rules, the native BookmarksBarView's: what fits and what goes behind
// the chevron (Other Bookmarks keeps the end), where a drop lands, how a click opens, and the
// rows of a folder's native menu.
import { expect, test } from "bun:test";
import {
  COMPACT_METRICS as M,
  createOnBar,
  disposition,
  droppedTitle,
  droppedURL,
  finalIndex,
  groupChildren,
  indicatorX,
  insertionIndex,
  itemWidth,
  layoutBar,
  menuRows,
  menuTitle,
  moveOnBar,
} from "../src/browser-chrome/bookmarks-bar/model";
import type { Bookmark } from "../src/pages/bookmarks/types";

const node = (id: string, parent: string, index: number, kind: Bookmark["kind"] = "url", title = id): Bookmark => ({
  id,
  browser_profile_id: "default",
  parent,
  kind,
  index,
  title,
  url: kind === "url" ? `https://${id}.example/` : undefined,
  created_ms: 0,
});

test("an item is padding, icon, gap and title, capped at the widest item", () => {
  expect(itemWidth(0, M)).toBe(8 * 2 + 12);
  expect(itemWidth(40, M)).toBe(8 * 2 + 12 + 4 + 40);
  expect(itemWidth(10_000, M)).toBe(M.maxItem);
});

test("everything fits: no chevron, items 2 apart from the inset", () => {
  const layout = layoutBar([50, 60], 400, 0, M);
  expect(layout.visible).toBe(2);
  expect(layout.overflow).toBe(false);
  expect(layout.frames).toEqual([
    { x: 2, width: 50 },
    { x: 54, width: 60 },
  ]);
});

test("what does not fit goes behind the chevron, which takes an item's height of room", () => {
  // 2 + 100 + 2 + 100 + 2 + 100 = 306 > 300 - 2 (inset): the chevron takes 24 more.
  const layout = layoutBar([100, 100, 100], 300, 0, M);
  expect(layout.visible).toBe(2);
  expect(layout.overflow).toBe(true);
  expect(layout.chevronX).toBe(2 + 100 + 2 + 100 + 2);
  // Other Bookmarks keeps the end: one fewer fits.
  expect(layoutBar([100, 100, 100], 300, 80, M).visible).toBe(1);
});

test("the layout's cost follows the bar's width, not its items", () => {
  const widths = Array.from({ length: 100_000 }, () => 80);
  const layout = layoutBar(widths, 800, 0, M);
  expect(layout.visible).toBeLessThan(10);
  expect(layout.frames.length).toBe(layout.visible);
});

test("a drop lands before the first item whose middle is right of the pointer", () => {
  const frames = [
    { x: 2, width: 50 },
    { x: 54, width: 60 },
  ];
  expect(insertionIndex(frames, 10)).toBe(0);
  expect(insertionIndex(frames, 40)).toBe(1);
  expect(insertionIndex(frames, 500)).toBe(2);
  expect(indicatorX(frames, 0, M)).toBe(1);
  expect(indicatorX(frames, 2, M)).toBe(54 + 60 + 1);
  expect(indicatorX([], 0, M)).toBe(M.inset);
});

test("a drag right of its own slot counts the item once; a drop in place moves nothing", () => {
  expect(finalIndex(0, 2)).toBe(1);
  expect(finalIndex(2, 0)).toBe(0);
  expect(finalIndex(-1, 3)).toBe(3);
  const items = [node("a", "bar", 0), node("b", "bar", 1), node("c", "bar", 2)];
  expect(moveOnBar(items, "a", 3)).toEqual({ op: "move", bookmark: "a", parent: "bar", index: 2 });
  expect(moveOnBar(items, "b", 1)).toBeNull();
  expect(moveOnBar(items, "b", 2)).toBeNull();
  expect(createOnBar("p", "https://x.example/", "X", 1)).toMatchObject({
    op: "create",
    parent: "bar",
    index: 1,
    url: "https://x.example/",
  });
});

test("a dropped link: the first URI line, the link's own text as its title", () => {
  expect(droppedURL("# comment\r\nhttps://a.example/\r\nhttps://b.example/", "")).toBe("https://a.example/");
  expect(droppedURL("", "https://plain.example/")).toBe("https://plain.example/");
  expect(droppedURL("", "not a link")).toBeNull();
  expect(droppedTitle('<a href="https://a.example/">A &amp; <b>B</b></a>', "https://a.example/")).toBe("A & B");
  expect(droppedTitle("", "https://a.example/")).toBe("");
  expect(droppedTitle('<a href="https://a.example/">https://a.example/</a>', "https://a.example/")).toBe("");
});

test("a click opens as the native bar's did", () => {
  expect(disposition({ metaKey: false, shiftKey: false })).toBe("current");
  expect(disposition({ metaKey: true, shiftKey: false })).toBe("backgroundTab");
  expect(disposition({ metaKey: true, shiftKey: true })).toBe("newTab");
  expect(disposition({ metaKey: false, shiftKey: true })).toBe("newTab");
  expect(disposition({ metaKey: false, shiftKey: false }, true)).toBe("backgroundTab");
});

test("a folder menu: its children, subfolders nested, Open All past one link, (empty) for none", () => {
  const words = { empty: "(empty)", openAll: (count: number) => `Open All (${count})` };
  const rows = [
    node("work", "bar", 0, "folder", "Work"),
    node("docs", "work", 0, "folder", "Docs"),
    node("a", "work", 1),
    node("b", "work", 2),
  ];
  const menu = menuRows(groupChildren(rows), "work", words);
  expect(menu.map((row) => row.kind)).toEqual(["folder", "bookmark", "bookmark", "separator", "openAll"]);
  expect(menu[0]).toMatchObject({ kind: "folder", title: "Docs", children: [{ kind: "empty", title: "(empty)" }] });
  expect(menu[4]).toEqual({ kind: "openAll", folder: "work", title: "Open All (2)" });
  // The chevron's menu lists the hidden bar items only, with no Open All.
  const overflow = menuRows(groupChildren(rows), null, words, [rows[0]!]);
  expect(overflow.map((row) => row.kind)).toEqual(["folder"]);
  expect(menuTitle("x".repeat(70))).toBe(`${"x".repeat(57)}…`);
});
