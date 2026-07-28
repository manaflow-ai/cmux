import { describe, expect, test } from "bun:test";

import {
  shortcutCategories,
  shortcutSequences,
  type ShortcutSequence,
} from "../data/cmux-shortcuts";

const shortcutsById = new Map(
  shortcutCategories
    .flatMap((category) => category.shortcuts)
    .map((shortcut) => [shortcut.id, shortcut]),
);

describe("keyboard shortcut sequence data", () => {
  const cases = [
    ["diffViewerScrollToTop", [[["G"], ["G"]]]],
    ["diffViewerNextFile", [[["]"], ["F"]]]],
    ["diffViewerPreviousFile", [[["["], ["F"]]]],
  ] satisfies Array<[string, ShortcutSequence[]]>;

  for (const [id, expectedSequences] of cases) {
    test(`${id} exposes its strokes as an ordered chord`, () => {
      const shortcut = shortcutsById.get(id);

      expect(shortcut).toBeDefined();
      expect(shortcutSequences(shortcut!)).toEqual(expectedSequences);
    });
  }
});
