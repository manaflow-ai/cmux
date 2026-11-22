import { describe, expect, test } from "bun:test";
import { editPatch } from "../diff";
import { changeSetFiles, patchHunks, readChangeSet } from "./model";

const numbers = (patch: string) =>
  patchHunks(patch).map((hunk) =>
    hunk.lines.map((line) => `${line.type[0]}${line.oldLine ?? ""}:${line.newLine ?? ""} ${line.text}`),
  );

describe("git scope patches", () => {
  test("lines number from their hunk's header", () => {
    expect(numbers("@@ -10,3 +10,3 @@ export function f() {\n a\n-b\n+B\n c\n")).toEqual([
      ["c10:10 a", "d11: b", "a:11 B", "c12:12 c"],
    ]);
  });

  test("a blank context line trimmed in transit still counts", () => {
    expect(numbers("@@ -1,4 +1,4 @@\n a\n\n-b\n+c\n d\n")).toEqual([["c1:1 a", "c2:2 ", "d3: b", "a:3 c", "c4:4 d"]]);
  });

  test("a hunk that claims more lines than the patch holds ends with the patch", () => {
    expect(numbers("@@ -1,3 +1,3 @@\n-a\n+b\n c\n")).toEqual([["d1: a", "a:1 b", "c2:2 c"]]);
  });

  test("a CRLF patch reads as lines without the carriage return", () => {
    expect(numbers("@@ -1,2 +1,2 @@\r\n a\r\n-b\r\n+c\r\n")).toEqual([["c1:1 a", "d2: b", "a:2 c"]]);
  });

  test("the no-newline marker and lines past a hunk's count are not lines", () => {
    expect(numbers("@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n")).toEqual([
      ["d1: a", "a:1 b"],
    ]);
  });

  test("a new, a deleted and a binary file", () => {
    const changeSet = readChangeSet(
      {
        root: "/repo/",
        files: [
          { path: "new.ts", status: "added", additions: 1, deletions: 0, patch: "@@ -0,0 +1 @@\n+x\n" },
          { path: "old.ts", status: "deleted", additions: 0, deletions: 1, patch: "@@ -1 +0,0 @@\n-x\n" },
          { path: "logo.png", status: "modified", additions: 0, deletions: 0, binary: true },
          { status: "modified" },
        ],
      },
      "uncommitted",
    )!;
    const [created, deleted, binary, ...rest] = changeSetFiles(changeSet);
    expect(rest).toEqual([]);
    expect([created!.path, created!.created, deleted!.deleted, binary!.binary]).toEqual([
      "/repo/new.ts",
      true,
      true,
      true,
    ]);
    expect(editPatch(created!, created!.edits[0]!)).toBe(
      "diff --git a/new.ts b/new.ts\n--- /dev/null\n+++ b/new.ts\n@@ -0,0 +1,1 @@\n+x\n",
    );
    expect(editPatch(deleted!, deleted!.edits[0]!)).toBe(
      "diff --git a/old.ts b/old.ts\n--- a/old.ts\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-x\n",
    );
    expect(binary!.edits[0]!.hunks).toEqual([]);
  });
});
