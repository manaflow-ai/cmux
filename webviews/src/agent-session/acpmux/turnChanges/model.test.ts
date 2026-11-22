import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { fileUndo, readUndoReply, turnChanges, undoFiles, undoSummary } from "./model";

const edit = (id: string, path: string, oldText: string | undefined, newText: string, status = "completed") => ({
  kind: "tool" as const,
  text: "Edit",
  tool: {
    id,
    title: "Edit",
    kind: "edit",
    status,
    diffs: [{ path, ...(oldText === undefined ? {} : { oldText }), newText }],
  },
});
const row = (items: ReturnType<typeof edit>[]): AcpmuxRow => ({
  id: "r",
  version: 1,
  at: 0,
  kind: "activity",
  ended: true,
  items,
});

describe("edited-files Undo data", () => {
  test("whole-file edits chain: Undo writes the first text back while the file holds the last", () => {
    expect(
      fileUndo([
        { path: "/r/a.ts", oldText: "1\n", newText: "2\n" },
        { path: "/r/a.ts", oldText: "2\n", newText: "3\n" },
      ]),
    ).toEqual({ kind: "revert", before: "1\n", after: "3\n" });
  });

  test("a fragment edit breaks the chain: Cannot undo this edit", () => {
    expect(
      fileUndo([
        { path: "/r/a.ts", oldText: "return 1", newText: "return 2" },
        { path: "/r/a.ts", oldText: "let x", newText: "const x" },
      ]),
    ).toEqual({ kind: "cannot" });
  });

  test("a file the turn created goes to the Trash; a path the agent wrote relative cannot be undone", () => {
    expect(fileUndo([{ path: "/r/new.ts", newText: "made\n" }])).toEqual({ kind: "trash", after: "made\n" });
    expect(fileUndo([{ path: "~/r/a.ts", oldText: "1", newText: "2" }])).toEqual({ kind: "cannot" });
    expect(fileUndo([{ path: "/r/a.ts", oldText: "x", newText: "" }])).toEqual({ kind: "cannot" });
  });

  test("a failed tool call wrote nothing, so it is left out", () => {
    const changes = turnChanges(
      "t1",
      [row([edit("1", "/r/a.ts", "1\n", "2\n"), edit("2", "/r/a.ts", "zzz", "yyy", "failed")])],
      [{ path: "/r/a.ts", additions: 1, deletions: 1 }],
    );
    expect(changes).toEqual({
      turnId: "t1",
      files: [{ path: "/r/a.ts", added: 1, removed: 1, undo: { kind: "revert", before: "1\n", after: "2\n" } }],
    });
    expect(undoFiles(changes.files)).toEqual([{ path: "/r/a.ts", before: "1\n", after: "2\n" }]);
  });

  test("the confirmation counts files to undo, files changed since the turn and edits it cannot undo", () => {
    const files = turnChanges(
      "t",
      [
        row([
          edit("1", "/r/a", "1", "2"),
          edit("2", "/r/b", "1", "2"),
          edit("3", "/r/c", "x", "y"),
          edit("4", "/r/c", "q", "w"),
        ]),
      ],
      ["/r/a", "/r/b", "/r/c"].map((path) => ({ path, additions: 1, deletions: 1 })),
    ).files;
    const dry = readUndoReply({
      files: [
        { path: "/r/a", status: "wouldRevert" },
        { path: "/r/b", status: "changed" },
      ],
    });
    expect(undoSummary(files, dry)).toEqual({ undo: 1, changed: 1, cannot: 1 });
    expect(readUndoReply({ files: [{ path: "/r/a", status: "rm -rf" }] }).get("/r/a")).toBe("cannotUndo");
  });
});
