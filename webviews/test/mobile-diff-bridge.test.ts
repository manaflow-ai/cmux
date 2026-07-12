import { expect, test } from "bun:test";
import { mobileDiffFiles, mobileDiffMessage } from "../src/mobile-diff-bridge";

test("mobile diff bridge preserves file order and stats", () => {
  const source = {
    paths: ["Sources/App.swift", "README.md"],
    pathToItemId: new Map([
      ["Sources/App.swift", "app"],
      ["README.md", "readme"],
    ]),
    statsByPath: new Map([
      ["Sources/App.swift", { added: 12, deleted: 3 }],
      ["README.md", { added: 2, deleted: 0 }],
    ]),
  } as any;

  expect(mobileDiffFiles(source)).toEqual([
    { id: "app", path: "Sources/App.swift", added: 12, deleted: 3 },
    { id: "readme", path: "README.md", added: 2, deleted: 0 },
  ]);
});

test("mobile diff messages carry the renderer generation", () => {
  expect(mobileDiffMessage(null, "item-1", 7)).toEqual({
    type: "files",
    files: [],
    generation: 7,
    selectedItemId: "item-1",
  });
});
