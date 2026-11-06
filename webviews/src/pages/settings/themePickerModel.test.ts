// The theme picker's rows (themePickerModel.ts): the search every theme choice on the page shares.
import { expect, test } from "bun:test";
import {
  CONFIG_ROW,
  isStarredRow,
  matchesQuery,
  pickerRows,
  rowGroupStart,
  rowTheme,
  toggledFavorites,
} from "./themePickerModel";

const names = ["0x96f", "Catppuccin Mocha", "Rose Pine", "Rose Pine Dawn", "Tokyo Night"];

test("no query lists the null choice first, then every theme in order", () => {
  expect(pickerRows({ names, query: "", nullChoice: true })).toEqual([CONFIG_ROW, ...names]);
  expect(pickerRows({ names, query: "  ", nullChoice: true })).toEqual([CONFIG_ROW, ...names]);
});

test("a query matches any part of the name, ignoring case and surrounding spaces, and hides the null choice", () => {
  expect(pickerRows({ names, query: "rose", nullChoice: true })).toEqual(["Rose Pine", "Rose Pine Dawn"]);
  expect(pickerRows({ names, query: " PINE d ", nullChoice: true })).toEqual(["Rose Pine Dawn"]);
  expect(pickerRows({ names, query: "night", nullChoice: true })).toEqual(["Tokyo Night"]);
  expect(pickerRows({ names, query: "zzz", nullChoice: true })).toEqual([]);
});

test("a list without the null choice (the app theme's light and dark sides) is only themes", () => {
  expect(pickerRows({ names, query: "", nullChoice: false })).toEqual(names);
});

test("matchesQuery is a trimmed, case-insensitive substring test", () => {
  expect(matchesQuery("Catppuccin Mocha", "MOCHA")).toBe(true);
  expect(matchesQuery("Catppuccin Mocha", "")).toBe(true);
  expect(matchesQuery("Catppuccin Mocha", "latte")).toBe(false);
});

test("starred themes list first, in the order they were starred, under their own heading, then every theme", () => {
  const rows = pickerRows({ names, query: "", nullChoice: true, favorites: ["Tokyo Night", "Rose Pine", "Gone"] });
  expect(rows.map(rowTheme)).toEqual([CONFIG_ROW, "Tokyo Night", "Rose Pine", ...names]);
  // Every row value is unique, so the starred copy and the full list's row are different rows.
  expect(new Set(rows).size).toBe(rows.length);
  expect(rows.map(isStarredRow)).toEqual([false, true, true, false, false, false, false, false]);
  expect(rows.map((_, index) => rowGroupStart(rows, index))).toEqual([
    null,
    "starred",
    null,
    "all",
    null,
    null,
    null,
    null,
  ]);
});

test("a query filters the starred group too; no starred match means no headings", () => {
  const favorites = ["Rose Pine", "Tokyo Night"];
  const rows = pickerRows({ names, query: "rose", nullChoice: true, favorites });
  expect(rows.map(rowTheme)).toEqual(["Rose Pine", "Rose Pine", "Rose Pine Dawn"]);
  expect(rows.map((_, index) => rowGroupStart(rows, index))).toEqual(["starred", "all", null]);
  const none = pickerRows({ names, query: "mocha", nullChoice: true, favorites });
  expect(none).toEqual(["Catppuccin Mocha"]);
  expect(rowGroupStart(none, 0)).toBeNull();
});

test("toggling a star adds it last or removes it", () => {
  expect(toggledFavorites([], "Nord")).toEqual(["Nord"]);
  expect(toggledFavorites(["Nord"], "Dracula")).toEqual(["Nord", "Dracula"]);
  expect(toggledFavorites(["Nord", "Dracula"], "Nord")).toEqual(["Dracula"]);
});
