import { expect, test } from "bun:test";
import { adoptTitle, bookmarkEditState, folderOptions } from "./model";

test("the host's push is checked, its folders kept in order", () => {
  const state = bookmarkEditState({
    revision: 3,
    isNew: true,
    title: "Page",
    folder: "bar",
    folders: [{ id: "bar", title: "Bookmarks Bar", depth: 0 }, { id: "bm_a", title: "A", depth: 1 }, { nope: 1 }],
    width: 320,
  });
  expect(state).toEqual({
    revision: 3,
    isNew: true,
    title: "Page",
    folder: "bar",
    folders: [
      { id: "bar", title: "Bookmarks Bar", depth: 0 },
      { id: "bm_a", title: "A", depth: 1 },
    ],
    width: 320,
  });
  expect(bookmarkEditState({ title: 1, folder: "bar" })).toBeNull();
  expect(bookmarkEditState(null)).toBeNull();
});

test("folders indent by depth, and a folder missing from the list still shows", () => {
  const folders = [
    { id: "bar", title: "Bookmarks Bar", depth: 0 },
    { id: "bm_a", title: "A", depth: 2 },
  ];
  expect(folderOptions({ folders }, "bm_a")).toEqual([
    { value: "bar", label: "Bookmarks Bar" },
    { value: "bm_a", label: " ".repeat(8) + "A" },
  ]);
  expect(folderOptions({ folders }, "bm_gone").at(-1)).toEqual({ value: "bm_gone", label: "bm_gone" });
});

test("a later title replaces the name only while the person has not edited it", () => {
  expect(adoptTitle("example.com", "example.com", "Example Domain")).toBe("Example Domain");
  expect(adoptTitle("My name", "example.com", "Example Domain")).toBe("My name");
  expect(adoptTitle("anything", null, "Example Domain")).toBe("Example Domain");
});
