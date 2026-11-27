import { describe, expect, test } from "bun:test";

import { applyPierreFileTreeGitStatus, planPierreFileTreeRefresh, selectPierreFileTreePath } from "../src/file-tree-refresh";

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
      requiresFullGitStatus: false,
      sourceFollowsPrevious: true,
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
      requiresFullGitStatus: true,
      sourceFollowsPrevious: false,
    });
  });

  test("requires a full git-status refresh for skipped same-length sources", () => {
    const previousSource = {
      paths: ["a.ts", "b.ts"],
    };
    const source = {
      paths: ["a.ts", "b.ts"],
      previousSource: {
        paths: ["a.ts", "b.ts"],
      },
    };

    expect(planPierreFileTreeRefresh(previousSource, source, source.paths)).toEqual({
      addedPaths: [],
      kind: "append",
      requiresFullGitStatus: true,
      sourceFollowsPrevious: false,
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

describe("applyPierreFileTreeGitStatus", () => {
  test("uses incremental patches when the Pierre model supports them", () => {
    const appliedPatches: unknown[] = [];
    const setStatuses: unknown[] = [];
    const patch = { set: [{ path: "added.ts", status: "added" }] };

    applyPierreFileTreeGitStatus(
      {
        applyGitStatusPatch: (nextPatch) => appliedPatches.push(nextPatch),
        setGitStatus: (gitStatus) => setStatuses.push(gitStatus),
      },
      {
        gitStatus: [{ path: "added.ts", status: "added" }],
        gitStatusPatch: patch,
      },
      false,
    );

    expect(appliedPatches).toEqual([patch]);
    expect(setStatuses).toEqual([]);
  });

  test("falls back to full status replacement for appended patches on older Pierre models", () => {
    const setStatuses: unknown[] = [];
    const gitStatus = [{ path: "added.ts", status: "added" }];

    applyPierreFileTreeGitStatus(
      {
        setGitStatus: (nextGitStatus) => setStatuses.push(nextGitStatus),
      },
      {
        gitStatus,
        gitStatusPatch: { set: gitStatus },
      },
      false,
    );

    expect(setStatuses).toEqual([gitStatus]);
  });

  test("uses full status replacement after a tree reset", () => {
    const appliedPatches: unknown[] = [];
    const setStatuses: unknown[] = [];
    const gitStatus = [
      { path: "existing.ts", status: "modified" },
      { path: "added.ts", status: "added" },
    ];
    const patch = { set: [{ path: "added.ts", status: "added" }] };

    applyPierreFileTreeGitStatus(
      {
        applyGitStatusPatch: (nextPatch) => appliedPatches.push(nextPatch),
        setGitStatus: (nextGitStatus) => setStatuses.push(nextGitStatus),
      },
      {
        gitStatus,
        gitStatusPatch: patch,
      },
      true,
    );

    expect(appliedPatches).toEqual([]);
    expect(setStatuses).toEqual([gitStatus]);
  });
});

describe("selectPierreFileTreePath", () => {
  test("uses exclusive Pierre selection when supported", () => {
    const calls: unknown[] = [];

    selectPierreFileTreePath(
      {
        getItem: () => ({
          select: () => calls.push("select"),
        }),
        scrollToPath: (path, options) => calls.push(["scroll", path, options]),
        selectOnlyPath: (path) => calls.push(["selectOnlyPath", path]),
      },
      "src/App.tsx",
    );

    expect(calls).toEqual([
      ["selectOnlyPath", "src/App.tsx"],
      ["scroll", "src/App.tsx", { focus: false, offset: "nearest" }],
    ]);
  });

  test("falls back to item selection for older Pierre models", () => {
    const calls: unknown[] = [];

    selectPierreFileTreePath(
      {
        getItem: (path) => ({
          select: () => calls.push(["select", path]),
        }),
        scrollToPath: (path, options) => calls.push(["scroll", path, options]),
      },
      "src/App.tsx",
    );

    expect(calls).toEqual([
      ["select", "src/App.tsx"],
      ["scroll", "src/App.tsx", { focus: false, offset: "nearest" }],
    ]);
  });
});
