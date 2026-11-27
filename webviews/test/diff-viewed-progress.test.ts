// The diff page's review progress (hq #19495): the "..." menu's Hide viewed files detail and the
// source pill's tooltip and suffix.
import { expect, test } from "bun:test";
import strings from "../src/pages/diff/generated/strings.json";
import {
  sourcePillTooltip,
  toggleViewedItem,
  viewedProgress,
  viewedProgressDetail,
  viewedProgressSuffix,
  type ViewedFileEntry,
} from "../src/viewed-files";

const en = (strings as Record<string, Record<string, string>>).en!;
const files = (count: number) =>
  Array.from({ length: count }, (_, index) => ({
    id: `src/file${index}.ts`,
    fileDiff: {
      name: `src/file${index}.ts`,
      hunks: [{ additionLines: index }],
    },
  }));

test("the menu detail counts the files marked viewed", () => {
  let items = files(30);
  let viewedByPath: ReadonlyMap<string, ViewedFileEntry> = new Map();
  for (const item of items.slice(0, 3)) ({ items, viewedByPath } = toggleViewedItem(items, viewedByPath, item.id));
  const progress = viewedProgress(items, viewedByPath);
  expect(progress).toEqual({ viewed: 3, total: 30 });
  expect(viewedProgressDetail(en["diffViewer.viewedProgressShort"]!, progress)).toBe("3 of 30 viewed");
});

test("no files, no progress anywhere", () => {
  expect(viewedProgressDetail("{viewed} of {total} viewed", { viewed: 0, total: 0 })).toBeNull();
  expect(viewedProgressDetail("{viewed} of {total} viewed", null)).toBeNull();
  expect(viewedProgressSuffix({ viewed: 0, total: 0 })).toBeNull();
  expect(
    sourcePillTooltip({
      source: "Branch",
      stats: null,
      progress: null,
      template: "{viewed} of {total} files viewed",
    }),
  ).toBeNull();
});

test("the source pill's tooltip names the source, its counts and the progress", () => {
  const template = en["diffViewer.filesViewedProgress"]!;
  expect(
    sourcePillTooltip({
      source: "Branch",
      stats: { added: "+694", deleted: "-683" },
      progress: { viewed: 3, total: 30 },
      template,
    }),
  ).toBe("Branch: +694 -683 · 3 of 30 files viewed");
  expect(
    sourcePillTooltip({
      source: "Uncommitted",
      stats: { added: "+4" },
      progress: { viewed: 0, total: 2 },
      template,
    }),
  ).toBe("Uncommitted: +4 · 0 of 2 files viewed");
  expect(
    sourcePillTooltip({
      source: "Branch",
      stats: null,
      progress: { viewed: 1, total: 1 },
      template,
    }),
  ).toBe("Branch · 1 of 1 files viewed");
});

test("the pill suffix is viewed/total", () => {
  expect(viewedProgressSuffix({ viewed: 3, total: 30 })).toBe("3/30");
});

test("every locale has the menu detail with both placeholders", () => {
  for (const [locale, table] of Object.entries(strings as Record<string, Record<string, string>>)) {
    const value = table["diffViewer.viewedProgressShort"];
    expect(value, locale).toBeDefined();
    expect(value!.includes("{viewed}") && value!.includes("{total}"), locale).toBe(true);
  }
});
