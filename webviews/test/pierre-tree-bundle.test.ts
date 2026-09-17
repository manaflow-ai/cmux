import { describe, expect, test } from "bun:test";

describe("vendored Pierre tree bundle", () => {
  test("supports the public APIs used by the diff viewer", async () => {
    const { FileTree, preparePresortedFileTreeInput } = await import(
      "../../Resources/markdown-viewer/diff-viewer/trees.mjs"
    );
    const paths = ["src/App.tsx"];
    const tree = new FileTree({
      gitStatus: [{ path: "src/App.tsx", status: "modified" }],
      initialExpansion: "open",
      preparedInput: preparePresortedFileTreeInput(paths),
      sort: () => 0,
    });

    try {
      expect(tree.getItem("src/App.tsx")?.getPath()).toBe("src/App.tsx");

      tree.batch([{ path: "src/viewer-controller.ts", type: "add" }]);
      tree.setGitStatus([{ path: "src/viewer-controller.ts", status: "added" }]);

      expect(tree.getItem("src/viewer-controller.ts")?.getPath()).toBe("src/viewer-controller.ts");

      const nextPaths = ["README.md", "webviews/src/App.tsx"];
      tree.resetPaths(nextPaths, {
        preparedInput: preparePresortedFileTreeInput(nextPaths),
      });

      expect(tree.getItem("src/App.tsx")).toBeNull();
      expect(tree.getItem("README.md")?.getPath()).toBe("README.md");
      expect(tree.getItem("webviews/src/App.tsx")?.getPath()).toBe("webviews/src/App.tsx");
    } finally {
      tree.cleanUp();
    }
  });
});
