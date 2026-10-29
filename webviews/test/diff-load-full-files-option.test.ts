// Load full files loads each shown file's two sides so its "N unmodified lines" gaps expand from
// their chevrons, 20 lines a click. It no longer turns on Expand Unchanged (the saved setting that
// shows every line at once), so a big file never draws whole by itself.
import { expect, test } from "bun:test";
import { EXPANSION_LINE_COUNT, codeViewOptions } from "../src/pierre-options";
import { NO_HOST_CAPABILITIES, overflowMenuItems } from "../src/toolbar-model";

const row = (loadFullFiles: boolean, fullFiles = true) =>
  overflowMenuItems(
    { hideImports: false, hideWhitespace: false, loadFullFiles, richPreview: false, wordDiffs: true },
    { ...NO_HOST_CAPABILITIES, fullFiles },
  ).find((item) => item.id === "load-full-files")!;

test("the row's check follows Load full files, where the host can read the files", () => {
  expect(row(true)).toMatchObject({ checked: true, available: true });
  expect(row(false)).toMatchObject({ checked: false, available: true });
  expect(row(true, false)).toMatchObject({ checked: false, available: false });
});

test("a gap's chevron shows a few lines at a time, and nothing expands by itself", () => {
  const options = codeViewOptions(
    {
      collapsed: false,
      colors: "theme",
      diffIndicators: "bars",
      expandUnchanged: false,
      groupByKind: false,
      hideWhitespace: false,
      hideImports: false,
      loadFullFiles: true,
      richPreview: false,
      layout: "unified",
      lineNumbers: true,
      showBackgrounds: true,
      showBulkActions: true,
      wordDiffs: true,
      wordWrap: false,
    },
    { theme: undefined } as never,
  );
  expect(EXPANSION_LINE_COUNT).toBe(20);
  expect(options.expansionLineCount).toBe(20);
  expect(options.expandUnchanged).toBe(false);
});
