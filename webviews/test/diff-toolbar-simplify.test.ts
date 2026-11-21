// The diff toolbar pill holds what a reader reaches for while reading: the "..." menu, Find, the
// layout and the files list (Lawrence, 2026-11-20: "cleanup diff viewer", "drastically simplify").
// Refresh, Word wrap and Collapse all moved into the "..." menu: the viewer refreshes itself and
// offers Refresh inline when the diff changes under the reader (diff-viewer/freshness.ts), and the
// other two are set once, not per glance.
import { expect, test } from "bun:test";
import { NO_HOST_CAPABILITIES, overflowMenuItems, toolbarPillButtons } from "../src/toolbar-model";

const pillState = (options: { collapsed?: boolean; wordWrap?: boolean } = {}) => ({
  options: { collapsed: false, layout: "auto" as const, wordWrap: false, ...options },
  filesVisible: true,
  optionsOpen: false,
  findOpen: false,
});

const menu = (options: { collapsed?: boolean; wordWrap?: boolean } = {}) =>
  overflowMenuItems(
    {
      collapsed: false,
      hideImports: false,
      hideWhitespace: false,
      loadFullFiles: false,
      richPreview: false,
      wordDiffs: true,
      wordWrap: false,
      ...options,
    },
    NO_HOST_CAPABILITIES,
  );

test("the pill holds the menu, Find, the layout and the files list, nothing else", () => {
  expect(toolbarPillButtons(pillState()).map((button) => button.id)).toEqual(["options", "find", "layout", "files"]);
});

test("Word wrap is a checked row in the menu that follows the option", () => {
  expect(menu({ wordWrap: false }).find((item) => item.id === "word-wrap")).toMatchObject({
    labelKey: "wordWrap",
    checked: false,
    available: true,
  });
  expect(menu({ wordWrap: true }).find((item) => item.id === "word-wrap")).toMatchObject({ checked: true });
});

test("Collapse all is a menu action that names what it will do", () => {
  const row = menu({ collapsed: false }).find((item) => item.id === "collapse-all");
  expect(row).toMatchObject({ labelKey: "collapseAllDiffs", available: true });
  // An action, not a toggle: no check mark.
  expect(row?.checked).toBeUndefined();
  expect(menu({ collapsed: true }).find((item) => item.id === "collapse-all")).toMatchObject({
    labelKey: "expandAllDiffs",
  });
});

test("Refresh stays reachable from the menu", () => {
  const row = menu().find((item) => item.id === "refresh");
  expect(row).toMatchObject({ labelKey: "refresh", available: true });
  expect(row?.checked).toBeUndefined();
});
