import { describe, expect, test } from "bun:test";

import { planPierreFileTreeRefresh } from "../src/file-tree-refresh";

describe("planPierreFileTreeRefresh", () => {
  test("appends suffix paths from the same streaming source", () => {
    const paths = ["src/App.tsx", "src/main.tsx"];
    const previousSource = {
      pathCount: 1,
      paths,
    };
    paths.push("src/viewer-controller.ts");
    const source = {
      pathCount: paths.length,
      paths,
      previousSource,
    };

    expect(planPierreFileTreeRefresh(previousSource, source, paths)).toEqual({
      addedPaths: ["src/main.tsx", "src/viewer-controller.ts"],
      kind: "append",
    });
  });

  test("appends when a new source preserves the previous path prefix", () => {
    const previousSource = {
      paths: ["a.ts", "b.ts"],
    };
    const source = {
      paths: ["a.ts", "b.ts", "c.ts"],
    };

    expect(planPierreFileTreeRefresh(previousSource, source, source.paths)).toEqual({
      addedPaths: ["c.ts"],
      kind: "append",
    });
  });

  test("resets when paths are reordered or removed", () => {
    const previousSource = {
      paths: ["a.ts", "b.ts"],
    };

    expect(planPierreFileTreeRefresh(previousSource, { paths: ["b.ts", "a.ts"] }, ["b.ts", "a.ts"])).toEqual({
      kind: "reset",
    });
    expect(planPierreFileTreeRefresh(previousSource, { paths: ["a.ts"] }, ["a.ts"])).toEqual({
      kind: "reset",
    });
  });
});
