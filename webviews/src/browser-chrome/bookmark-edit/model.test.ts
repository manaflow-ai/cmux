import { expect, test } from "bun:test";
import { adoptTitle, bookmarkEditState, FOLDER_MENU_LIMIT, folderMenu, folderOptions } from "./model";

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

// 1,500 folders: past the 1,000 rows a level the app's popup host draws (NativePopupModel+Validation).
const many = [
  { id: "bar", title: "Bookmarks Bar", depth: 0 },
  ...Array.from({ length: 1500 }, (_, n) => ({ id: `bm_${n}`, title: `Folder ${n}`, depth: n % 2 === 0 ? 1 : 2 })),
  { id: "other", title: "Other Bookmarks", depth: 0 },
];

test("a big profile's Folder menu stays within the host's rows and its search finds any folder", () => {
  const first = folderMenu({ folders: many }, "bar", "");
  expect(first.options.length).toBe(FOLDER_MENU_LIMIT);
  expect(first.hidden).toBe(many.length - FOLDER_MENU_LIMIT);
  // The current folder past the first rows still shows, checked in the menu.
  const deep = folderMenu({ folders: many }, "bm_1499", "");
  expect(deep.options.length).toBe(FOLDER_MENU_LIMIT + 1);
  expect(deep.options.at(-1)).toEqual({ value: "bm_1499", label: "\u00a0".repeat(8) + "Folder 1499" });
  // Every folder is one search away, with the folders it is in.
  for (const n of [0, 777, 1499]) {
    const found = folderMenu({ folders: many }, "bar", `folder ${n}`).options.find((o) => o.value === `bm_${n}`);
    expect(found?.label).toBe(`Folder ${n}`);
  }
  expect(folderMenu({ folders: many }, "bar", "FOLDER 1499").options).toEqual([
    { value: "bm_1499", label: "Folder 1499", description: "Bookmarks Bar › Folder 1498" },
  ]);
  const broad = folderMenu({ folders: many }, "bar", "folder");
  expect(broad.options.length).toBe(FOLDER_MENU_LIMIT);
  expect(broad.hidden).toBe(1500 - FOLDER_MENU_LIMIT);
  expect(folderMenu({ folders: many }, "bar", "nothing like it")).toEqual({ options: [], hidden: 0 });
});
