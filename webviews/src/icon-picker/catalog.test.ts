// The system SF Symbol catalog in the picker (ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS, S3): the host
// sends the names in the system's order, each name's search keywords and the system categories;
// the Symbols tab shows one section per category and finds symbols by keyword.
import { describe, expect, test } from "bun:test";
import { decodeEmojiTable, type RawEmojiTable } from "./emojiData";
import raw from "./generated/emoji-data.json";
import { PickerStore } from "./store";
import type { SymbolCatalog } from "./symbols";

const emoji = decodeEmojiTable(raw as RawEmojiTable);

const CATALOG: SymbolCatalog = {
  names: ["folder", "folder.fill", "star", "star.fill", "car", "zz.uncategorized"],
  keywords: ["directory", "directory", "favorite vip", "favorite vip", "automobile", ""],
  categories: [
    { key: "all", icon: "square.grid.2x2", members: [0, 1, 2, 3, 4, 5] },
    { key: "draw", icon: "scribble", members: [2] },
    { key: "multicolor", icon: "paintpalette", members: [1] },
    { key: "objectsandtools", icon: "folder", members: [0, 1, 2, 3] },
    { key: "transportation", icon: "car.fill", members: [4] },
  ],
};

function store(catalog: SymbolCatalog | readonly string[] = CATALOG) {
  const picker = new PickerStore({ emoji, titles: (id) => `T(${id})` });
  picker.configure(catalog);
  picker.setTab("symbol");
  return picker;
}

const titles = (picker: PickerStore) =>
  picker
    .getSnapshot()
    .layout.rows.filter((row) => row.kind === "header")
    .map((row) => row.title);

const names = (picker: PickerStore) => picker.getSnapshot().layout.items.map((cell) => cell.symbol);

describe("symbol catalog", () => {
  test("one section per shown system category, in the system's order, then the rest", () => {
    const picker = store();
    // "all" is the whole list and "draw" is an animation feature: neither is a section.
    expect(titles(picker)).toEqual([
      "T(symbolCategory.multicolor)",
      "T(symbolCategory.objectsandtools)",
      "T(symbolCategory.transportation)",
      "T(symbolCategory.other)",
    ]);
    // A symbol shows in every category it belongs to (as in the SF Symbols app).
    expect(names(picker)).toEqual(["folder.fill", "folder", "folder.fill", "star", "star.fill", "car", "zz.uncategorized"]);
  });

  test("keywords find a symbol whose name does not contain the word", () => {
    const picker = store();
    picker.setQuery("favorite");
    expect(names(picker)).toEqual(["star", "star.fill"]);
    picker.setQuery("automobile");
    expect(names(picker)).toEqual(["car"]);
    // A name match still ranks above a keyword match.
    picker.setQuery("folder");
    expect(names(picker)).toEqual(["folder", "folder.fill"]);
  });

  test("search shows each symbol once, even when it is in several categories", () => {
    const picker = store();
    picker.setQuery("fill");
    expect(names(picker)).toEqual(["folder.fill", "star.fill"]);
  });

  test("multicolor support comes from the system's multicolor category", () => {
    const picker = store();
    const cells = picker.getSnapshot().layout.items;
    expect(cells.find((cell) => cell.symbol === "folder.fill")?.multicolor).toBe(true);
    expect(cells.find((cell) => cell.symbol === "folder")?.multicolor).toBe(false);
  });

  test("a bare name list (fallback catalog) is one sorted section", () => {
    const picker = store(["b", "a"]);
    expect(titles(picker)).toEqual(["T(allSymbols)"]);
    expect(names(picker)).toEqual(["b", "a"]);
  });
});
