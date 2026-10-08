// One grid of emoji and SF Symbols with an All Categories menu (cx-fh0e, the launcher-style
// picker): All Categories is Frequently Used, the emoji groups, then SF Symbols, each header with
// its count; the menu narrows the grid to one category; search covers emoji and symbols within
// the category; Escape steps back; Alt-Down and Alt-Up jump between sections. Model level: no DOM.
import { describe, expect, test } from "bun:test";
import { decodeEmojiTable, type RawEmojiTable } from "./emojiData";
import raw from "./generated/emoji-data.json";
import { layoutGrid, sectionAt } from "./gridModel";
import { pickerKeyAction } from "./keyboard";
import type { PickerPrefs } from "./recents";
import { PickerStore } from "./store";
import type { SymbolCatalog } from "./symbols";

const emoji = decodeEmojiTable(raw as RawEmojiTable);
const metrics = { cell: 36, header: 28 };
const CATALOG: SymbolCatalog = {
  names: ["folder", "star", "car", "zz.loose"],
  keywords: ["directory", "favorite", "automobile", ""],
  categories: [
    { key: "objectsandtools", icon: "folder", members: [0, 1] },
    { key: "transportation", icon: "car.fill", members: [2] },
  ],
};
const NOW = 1_000_000;

function store(recents: string[] = []) {
  const prefs: PickerPrefs = {
    tone: 0,
    recents: recents.map((key, rank) => ({ key, count: recents.length - rank, last: NOW })),
  };
  const picker = new PickerStore({
    emoji,
    titles: (id) => `T(${id})`,
    prefs: { load: () => prefs, save: () => undefined },
    now: () => NOW,
  });
  picker.configure(CATALOG);
  return picker;
}

const headers = (picker: PickerStore) =>
  picker.getSnapshot().layout.rows.flatMap((row) => (row.kind === "header" ? [`${row.title} ${row.count}`] : []));
const items = (picker: PickerStore) =>
  picker.getSnapshot().layout.items.map((cell) => cell.emoji ?? `sf:${cell.symbol}`);

describe("section anchors", () => {
  const layout = layoutGrid(
    [
      { id: "a", title: "A", items: [1, 2, 3, 4, 5] },
      { id: "empty", title: "E", items: [] },
      { id: "results", title: "", items: [9] },
      { id: "b", title: "B", items: [6, 7] },
    ],
    3,
    metrics,
  );

  test("each titled section with items has its header offset and first item", () => {
    expect(layout.sections).toEqual([
      { id: "a", title: "A", top: 0, first: 0 },
      { id: "b", title: "B", top: 136, first: 6 },
    ]);
  });

  test("the section at a scroll offset is the last one whose header is at or above it", () => {
    expect(sectionAt(layout, 0)).toBe("a");
    expect(sectionAt(layout, 135)).toBe("a");
    expect(sectionAt(layout, 136)).toBe("b");
    expect(sectionAt(layout, 9999)).toBe("b");
    expect(sectionAt(layoutGrid([], 3, metrics), 0)).toBeNull();
  });
});

describe("one grid of emoji and symbols", () => {
  test("All Categories: Frequently Used (emoji and symbols), the emoji groups, then SF Symbols, with counts", () => {
    const picker = store(["symbol:star", "emoji:🐱"]);
    const groups = emoji.groups.map((group) => {
      const count = emoji.records.filter((record) => record.group === group).length;
      return `T(${group}) ${count}`;
    });
    expect(headers(picker)).toEqual(["T(recent) 2", ...groups, "T(sfSymbols) 4"]);
    expect(items(picker).slice(0, 2)).toEqual(["sf:star", "🐱"]);
    expect(items(picker).slice(-4)).toEqual(["sf:folder", "sf:star", "sf:car", "sf:zz.loose"]);
    const snap = picker.getSnapshot();
    expect(snap.showsEmoji && snap.showsSymbols).toBe(true);
    expect(snap.active).toBe(0);
  });

  test("Frequently Used shows two rows in All Categories and every recent in its own category", () => {
    const recents = emoji.records.slice(0, 20).map((record) => `emoji:${record.emoji}`);
    const picker = store(recents);
    picker.setWidth(8 * 72);
    expect(headers(picker)[0]).toBe("T(recent) 16");
    picker.setCategory("recent");
    expect(headers(picker)).toEqual(["T(recent) 20"]);
  });

  test("the category menu lists each category with its count; choosing one shows only it", () => {
    const picker = store(["emoji:🐱"]);
    const options = picker.getSnapshot().categories;
    expect(options.map((option) => option.id)).toEqual([
      "all",
      "recent",
      ...emoji.groups,
      "sfSymbols",
      "symbolCategory.objectsandtools",
      "symbolCategory.transportation",
      "symbolCategory.other",
    ]);
    expect(options[0]).toMatchObject({ label: "T(all)", count: emoji.records.length + 4 });
    expect(options.find((option) => option.id === "flags")).toMatchObject({ kind: "emoji", glyph: "🏁" });
    expect(options.find((option) => option.id === "symbolCategory.transportation")).toMatchObject({
      count: 1,
      symbol: "car.fill",
    });

    picker.setCategory("flags");
    expect(headers(picker)).toEqual([`T(flags) ${emoji.records.filter((r) => r.group === "flags").length}`]);
    expect(picker.getSnapshot().showsSymbols).toBe(false);

    picker.setCategory("sfSymbols");
    expect(headers(picker)).toEqual([
      "T(symbolCategory.objectsandtools) 2",
      "T(symbolCategory.transportation) 1",
      "T(symbolCategory.other) 1",
    ]);
    expect(picker.getSnapshot().showsEmoji).toBe(false);

    picker.setCategory("symbolCategory.transportation");
    expect(items(picker)).toEqual(["sf:car"]);
    picker.setCategory("no-such-category");
    expect(picker.getSnapshot().category).toBe("all");
  });

  test("search covers emoji and symbol names and keywords, within the category", () => {
    const picker = store();
    picker.setQuery("star");
    const [emojiResults, symbolResults] = headers(picker);
    expect(emojiResults.startsWith("T(results.emoji) ")).toBe(true);
    expect(symbolResults).toBe("T(results.sfSymbols) 1");
    expect(items(picker)).toContain("⭐");
    expect(items(picker).at(-1)).toBe("sf:star");
    picker.setQuery("automobile");
    expect(items(picker)).toContain("sf:car");
    picker.setCategory("sfSymbols");
    expect(picker.getSnapshot().query).toBe("automobile");
    expect(items(picker)).toEqual(["sf:car"]);
    // An emoji outside the chosen group is not a result.
    picker.setCategory("food-drink");
    picker.setQuery("rocket");
    expect(items(picker)).toEqual([]);
  });

  test("Escape steps back: the search, then the category, then nothing (the picker closes)", () => {
    const picker = store();
    picker.setCategory("flags");
    picker.setQuery("japan");
    expect(picker.back()).toBe(true);
    expect(picker.getSnapshot()).toMatchObject({ query: "", category: "flags" });
    expect(picker.back()).toBe(true);
    expect(picker.getSnapshot().category).toBe("all");
    expect(picker.back()).toBe(false);
    picker.setView("image");
    expect(picker.back()).toBe(true);
    expect(picker.getSnapshot().view).toBe("grid");
  });

  test("Ctrl-Tab steps through the categories; a session opens on the current icon's kind", () => {
    const picker = store();
    picker.stepCategory(1);
    expect(picker.getSnapshot().category).toBe(emoji.groups[0]);
    picker.stepCategory(-1);
    picker.stepCategory(-1);
    expect(picker.getSnapshot().category).toBe("symbolCategory.other");
    picker.reset("symbol");
    expect(picker.getSnapshot()).toMatchObject({ view: "grid", category: "sfSymbols", query: "" });
    picker.reset("svg");
    expect(picker.getSnapshot().view).toBe("svg");
    picker.reset("emoji");
    expect(picker.getSnapshot()).toMatchObject({ view: "grid", category: "all" });
  });

  test("tiles: up to eight square columns; the pitch follows the width", () => {
    const picker = store();
    picker.setWidth(576);
    expect(picker.getSnapshot().layout.columns).toBe(8);
    expect(picker.getSnapshot().layout.metrics.cell).toBe(72);
    picker.setWidth(300);
    expect(picker.getSnapshot().layout.columns).toBe(5);
    expect(picker.getSnapshot().layout.metrics.cell).toBe(60);
  });

  test("a jump activates the section's first cell; Alt-Down and Alt-Up step through the sections", () => {
    const picker = store();
    const top = picker.jump("flags");
    const flags = picker.getSnapshot().layout.sections.find((section) => section.id === "flags")!;
    expect(top).toBe(flags.top);
    expect(picker.getSnapshot().active).toBe(flags.first);
    expect(picker.jump("no-such-section")).toBeNull();
    picker.setActive(0);
    const [first, second] = picker.getSnapshot().layout.sections;
    expect(picker.jumpBy(1)).toBe(second.top);
    expect(picker.getSnapshot().active).toBe(second.first);
    expect(picker.jumpBy(-1)).toBe(first.top);
    expect(picker.jumpBy(-1)).toBe(first.top);
    const base = { key: "ArrowDown", ctrlKey: false, metaKey: false, altKey: true, shiftKey: false };
    expect(pickerKeyAction(base)).toEqual({ kind: "section", step: 1 });
    expect(pickerKeyAction({ ...base, key: "ArrowUp" })).toEqual({ kind: "section", step: -1 });
  });
});
