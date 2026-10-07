import { expect, test } from "bun:test";
import { FileTree } from "@pierre/trees";
import { selectPierreFileTreePath } from "../src/file-tree-refresh";

test("following the file in view leaves only that tree row selected", () => {
  const model = new FileTree({
    paths: ["CLAUDE.md", "plans/a.md", "plans/b.md"],
    initialExpansion: "open",
    initialSelectedPaths: ["CLAUDE.md"],
  });
  selectPierreFileTreePath(model as any, "plans/a.md");
  expect(model.getSelectedPaths()).toEqual(["plans/a.md"]);
  selectPierreFileTreePath(model as any, "plans/b.md");
  expect(model.getSelectedPaths()).toEqual(["plans/b.md"]);
});
