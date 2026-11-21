// The diff toolbar pill holds three buttons: the "..." menu, the layout and the files list (Lawrence,
// 2026-11-20: "cleanup diff viewer", "drastically simplify"; a1315's cuts: "keep file list toggle,
// unified/split, and one More menu; everything else into More"). Refresh, Word wrap and Collapse all
// moved into the "..." menu: the viewer refreshes itself and offers Refresh inline when the diff
// changes under the reader (diff-viewer/freshness.ts), and the other two are set once, not per
// glance. Find is the menu's first row and Cmd-F, Plain English a menu row.
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

test("the pill holds the menu, the layout and the files list, nothing else", () => {
  expect(toolbarPillButtons(pillState()).map((button) => button.id)).toEqual(["options", "layout", "files"]);
});

test("Find is the menu's first row, an action", () => {
  const row = menu()[0];
  expect(row).toMatchObject({ id: "find", labelKey: "findInDiff", available: true });
  expect(row?.checked).toBeUndefined();
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
