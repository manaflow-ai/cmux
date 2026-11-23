// A plated keycap reads as a Mac keyboard prints the key (Leo 2026-11-22: the palette's caps were
// "not even properly depicting the keys"): modifiers as glyphs, named keys as lowercase words.
import { expect, test } from "bun:test";
import { keycapKeys, keycapLegend, keycapStrokes } from "./keycapLegend";

test("named keys read as the words on the key", () => {
  for (const key of ["↩", "↵", "⏎", "Return", "Enter"]) expect(keycapLegend(key)).toBe("return");
  expect(keycapLegend("⇥")).toBe("tab");
  for (const key of ["⎋", "Esc", "esc", "Escape"]) expect(keycapLegend(key)).toBe("esc");
  expect(keycapLegend("⌫")).toBe("delete");
  expect(keycapLegend("Space")).toBe("space");
});

test("modifiers, letters, digits and arrows stay as given", () => {
  for (const key of ["⌘", "⌥", "⌃", "⇧", "K", "j", "2", "↑↓", "←"]) expect(keycapLegend(key)).toBe(key);
  expect(keycapLegend("⌘D")).toBe("⌘D");
  expect(keycapLegend("⌥⌘2")).toBe("⌥⌘2");
});

test("a combined key spaces its word from its modifiers, or splits one cap per key", () => {
  expect(keycapLegend("⌘↩")).toBe("⌘ return");
  expect(keycapLegend("⌘⇧↩")).toBe("⌘⇧ return");
  expect(keycapLegend("⌃⇥")).toBe("⌃ tab");
  expect(keycapKeys("⌘↩")).toEqual(["⌘", "return"]);
  expect(keycapKeys("⌥⌘2")).toEqual(["⌥", "⌘", "2"]);
});

test("a keycaps array splits into strokes at each non-modifier key", () => {
  expect(keycapStrokes(["⌘", "J", "S"])).toEqual([["⌘", "J"], ["S"]]);
  expect(keycapStrokes(["⇧", "⌘", "N"])).toEqual([["⇧", "⌘", "N"]]);
  expect(keycapStrokes(["⌘", "↩"])).toEqual([["⌘", "return"]]);
});
