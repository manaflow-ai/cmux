// The theme picker's rows (themePickerModel.ts): the search every theme choice on the page shares.
import { expect, test } from "bun:test";
import { CONFIG_ROW, matchesQuery, pickerRows } from "./themePickerModel";

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
