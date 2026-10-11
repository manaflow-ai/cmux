import { expect, test } from "bun:test";
import { showsFolderChoice } from "./FolderChoice";

const offered = {
  offered: true,
  freshChat: true,
  quick: false,
  projectDraft: undefined,
  sessionId: "session-1",
  missingFolder: false,
};

test("showsFolderChoice only offers a folder for a fresh folderless chat", () => {
  expect(showsFolderChoice(offered)).toBe(true);
  expect(showsFolderChoice({ ...offered, offered: false })).toBe(false);
  expect(showsFolderChoice({ ...offered, freshChat: false })).toBe(false);
  expect(showsFolderChoice({ ...offered, quick: true })).toBe(false);
  expect(showsFolderChoice({ ...offered, projectDraft: "/Users/you/src/cmux" })).toBe(false);
  expect(showsFolderChoice({ ...offered, missingFolder: true })).toBe(false);
});
