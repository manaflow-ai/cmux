// The toolbar's Jump to file button repeated the files list's own filter field beside it, as a
// bare chevron (diff viewer before shots, 2026-11-20). It shows only while the files list is
// hidden, and only for a diff with more than one file, where jumping means something.
import { expect, test } from "bun:test";
import { jumpToFileShown } from "../src/toolbar-model";

test("shown while the files list is hidden, for a diff of several files", () => {
  expect(jumpToFileShown({ filesVisible: false, fileCount: 30 })).toBe(true);
  expect(jumpToFileShown({ filesVisible: false, fileCount: 2 })).toBe(true);
});

test("hidden beside the files list, whose filter does the same", () => {
  expect(jumpToFileShown({ filesVisible: true, fileCount: 30 })).toBe(false);
});

test("hidden for a diff of one file or none", () => {
  expect(jumpToFileShown({ filesVisible: false, fileCount: 1 })).toBe(false);
  expect(jumpToFileShown({ filesVisible: false, fileCount: 0 })).toBe(false);
});
