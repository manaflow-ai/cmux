import { describe, expect, test } from "bun:test";
import { decodeEmojiTable, withTone, type RawEmojiTable } from "./emojiData";
import raw from "./generated/emoji-data.json";
import { layoutGrid, moveActive, rowAt, scrollToReveal, visibleRows } from "./gridModel";
import { dockedTitle } from "./VirtualGrid";
import { decodeIcon, encodeIcon, isValidIcon, type IconValue } from "./iconValue";
import { pickerKeyAction } from "./keyboard";
import { decodePrefs, EMPTY_PREFS, rankedKeys, recordUse } from "./recents";
import { search } from "./search";

const table = decodeEmojiTable(raw as RawEmojiTable);
const top = (query: string, n = 1) =>
  search(table.records, query)
    .slice(0, n)
    .map((record) => record.emoji);

describe("emoji table", () => {
  test("is pinned, versioned and complete", () => {
    expect(table.unicode).toEqual({ emoji: "17.0", cldr: "48.2.0", shortcodes: "17.0.0" });
    expect(table.records.length).toBeGreaterThan(1800);
    expect(table.groups).toContain("flags");
  });

  test("tone forms are uniform and in light-to-dark order", () => {
    const thumbs = table.records.find((record) => record.emoji === "👍")!;
    expect(withTone(thumbs, 0)).toBe("👍");
    expect(withTone(thumbs, 1)).toBe("👍🏻");
    expect(withTone(thumbs, 5)).toBe("👍🏿");
    const rocket = table.records.find((record) => record.emoji === "🚀")!;
    expect(withTone(rocket, 3)).toBe("🚀");
  });
});

describe("search", () => {
  test("English names, keywords and aliases", () => {
    expect(top("rocket")).toEqual(["🚀"]);
    expect(top("thumbs up")).toEqual(["👍"]);
    expect(top("japan", 2).sort()).toEqual(["🇯🇵", "🗾"].sort());
    expect(top("flag jp")).toEqual(["🇯🇵"]);
    expect(top("+1")).toEqual(["👍"]);
  });

  test("GitHub shortcodes, with or without colons", () => {
    expect(top(":tada:")).toEqual(["🎉"]);
    expect(top("thumbsup")).toEqual(["👍"]);
    expect(table.records.find((record) => record.emoji === "🎉")!.shortcodes[0]).toBe("tada");
  });

  test("Japanese names and keywords, kana folded", () => {
    expect(top("いいね")).toEqual(["👍"]);
    expect(top("サムズアップ")).toEqual(["👍"]);
    expect(top("さむずあっぷ")).toEqual(["👍"]);
    expect(top("ロケット")).toEqual(["🚀"]);
  });

  test("every token must match; no match is empty", () => {
    expect(search(table.records, "cat face rocket")).toEqual([]);
    expect(search(table.records, "zzzzqq")).toEqual([]);
  });

  test("an empty query keeps table order", () => {
    expect(
      search(table.records, "  ")
        .slice(0, 3)
        .map((r) => r.index),
    ).toEqual([0, 1, 2]);
  });

  test("recents break ties", () => {
    const hits = search(table.records, "heart");
    const later = hits[5];
    const boosted = search(table.records, "heart", new Map([[later.index, 9]]));
    expect(boosted.indexOf(later)).toBeLessThan(5);
  });
});

describe("grid layout", () => {
  const sections = [
    { id: "a", title: "A", items: [1, 2, 3, 4, 5] },
    { id: "empty", title: "E", items: [] },
    { id: "b", title: "B", items: [6, 7] },
  ];
  const layout = layoutGrid(sections, 3, { cell: 36, header: 28 });

  test("headers and rows with offsets; empty sections are skipped", () => {
    expect(layout.rows.map((row) => (row.kind === "header" ? row.title : row.items.join("")))).toEqual([
      "A",
      "123",
      "45",
      "B",
      "67",
    ]);
    expect(layout.rows.map((row) => row.top)).toEqual([0, 28, 64, 100, 128]);
    expect(layout.height).toBe(164);
    expect(layout.items).toEqual([1, 2, 3, 4, 5, 6, 7]);
  });

  test("window math", () => {
    expect(rowAt(layout, 0)).toBe(0);
    expect(rowAt(layout, 30)).toBe(1);
    expect(rowAt(layout, 1000)).toBe(4);
    expect(visibleRows(layout, 64, 36, 0)).toEqual({ start: 2, end: 4 });
  });

  test("keyboard moves keep the column and cross headers", () => {
    expect(moveActive(layout, 1, "down")).toBe(4); // 2 -> 5 (column 1)
    expect(moveActive(layout, 4, "down")).toBe(6); // 5 -> 7 across header B
    expect(moveActive(layout, 2, "down")).toBe(4); // 3 -> 5 (short row clamps)
    expect(moveActive(layout, 6, "up")).toBe(4);
    expect(moveActive(layout, 0, "up")).toBe(0);
    expect(moveActive(layout, 6, "right")).toBe(6);
    expect(moveActive(layout, 0, "end")).toBe(6);
    expect(moveActive(layout, -1, "down")).toBe(0);
    expect(moveActive(layoutGrid([], 3, { cell: 36, header: 28 }), 0, "down")).toBe(-1);
  });

  test("the docked header names the section at the top of the viewport", () => {
    expect(dockedTitle(layout, 0)).toBeNull();
    expect(dockedTitle(layout, 40)).toBe("A");
    expect(dockedTitle(layout, 100)).toBe("B");
    expect(dockedTitle(layout, 150)).toBe("B");
  });

  test("reveal scrolls only when needed and keeps the header", () => {
    expect(scrollToReveal(layout, 0, 0, 100)).toBeNull();
    expect(scrollToReveal(layout, 6, 0, 100)).toBe(64);
    expect(scrollToReveal(layout, 5, 120, 100)).toBe(100);
  });
});

describe("keys", () => {
  const key = (
    k: string,
    mods: Partial<Record<"ctrlKey" | "metaKey" | "altKey" | "shiftKey" | "isComposing", boolean>> = {},
  ) => ({
    key: k,
    ctrlKey: false,
    metaKey: false,
    altKey: false,
    shiftKey: false,
    ...mods,
  });

  test("Ctrl-N/J down, Ctrl-P/K up, arrows, Return, Escape, Ctrl-Tab", () => {
    expect(pickerKeyAction(key("n", { ctrlKey: true }))).toEqual({ kind: "move", move: "down" });
    expect(pickerKeyAction(key("j", { ctrlKey: true }))).toEqual({ kind: "move", move: "down" });
    expect(pickerKeyAction(key("p", { ctrlKey: true }))).toEqual({ kind: "move", move: "up" });
    expect(pickerKeyAction(key("k", { ctrlKey: true }))).toEqual({ kind: "move", move: "up" });
    expect(pickerKeyAction(key("ArrowLeft"))).toEqual({ kind: "move", move: "left" });
    expect(pickerKeyAction(key("Enter"))).toEqual({ kind: "pick" });
    expect(pickerKeyAction(key("Escape"))).toEqual({ kind: "cancel" });
    expect(pickerKeyAction(key("Tab", { ctrlKey: true, shiftKey: true }))).toEqual({ kind: "tab", step: -1 });
  });

  test("typing, Cmd chords and IME composition stay with the field", () => {
    expect(pickerKeyAction(key("a"))).toBeNull();
    expect(pickerKeyAction(key("n", { metaKey: true }))).toBeNull();
    expect(pickerKeyAction(key("Enter", { isComposing: true }))).toBeNull();
    expect(pickerKeyAction(key("ArrowDown", { isComposing: true }))).toBeNull();
  });
});

describe("icon value", () => {
  const values: IconValue[] = [
    { emoji: "👍🏽" },
    { symbol: "star.fill" },
    { image: `sha256-${"a".repeat(64)}` },
    { svg: `sha256-${"b".repeat(64)}` },
  ];

  test("wire round trip", () => {
    for (const value of values) {
      expect(isValidIcon(value)).toBe(true);
      expect(decodeIcon(encodeIcon(value))).toEqual(value);
    }
  });

  test("legacy strings and refusals", () => {
    expect(decodeIcon("🇯🇵")).toEqual({ emoji: "🇯🇵" });
    expect(decodeIcon("terminal")).toEqual({ symbol: "terminal" });
    expect(decodeIcon("ab cd")).toBeNull();
    expect(decodeIcon("👍👍")).toBeNull();
    expect(decodeIcon("image:sha256-xyz")).toBeNull();
    expect(decodeIcon("svg:../etc")).toBeNull();
    expect(isValidIcon({ emoji: "👍", symbol: "star" })).toBe(false);
    expect(isValidIcon({ image: "blob:sha256-00" })).toBe(false);
  });
});

describe("recents", () => {
  const day = 24 * 3600 * 1000;

  test("frecency: a fresh use outranks old repeated uses", () => {
    let prefs = EMPTY_PREFS;
    for (let i = 0; i < 3; i++) prefs = recordUse(prefs, "emoji:🐱", 0);
    prefs = recordUse(prefs, "emoji:🚀", 60 * day);
    expect(rankedKeys(prefs, 60 * day)).toEqual(["emoji:🚀", "emoji:🐱"]);
    expect(rankedKeys(prefs, 0)[0]).toBe("emoji:🐱");
  });

  test("decoding refuses garbage", () => {
    expect(decodePrefs(null)).toEqual(EMPTY_PREFS);
    expect(decodePrefs({ tone: 9, recents: [{ key: 1 }, { key: "emoji:🐱", count: 1, last: 0 }] })).toEqual({
      tone: 0,
      recents: [{ key: "emoji:🐱", count: 1, last: 0 }],
    });
  });
});
