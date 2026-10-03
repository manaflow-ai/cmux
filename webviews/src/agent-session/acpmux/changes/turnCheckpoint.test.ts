import { describe, expect, test } from "bun:test";
import { checkpointHunkKey, hunkKey, turnFiles } from "../diff";
import type { AcpmuxRow } from "../model";
import { readTurnCheckpoint, turnCounts, turnDisplay, type TurnCheckpointLoad } from "./turnCheckpoint";

const toolFiles = turnFiles([
  {
    id: "activity-2",
    version: 1,
    at: 2,
    kind: "activity",
    items: [
      {
        kind: "tool",
        text: "",
        tool: {
          id: "t1",
          title: "Edit",
          kind: "edit",
          status: "completed",
          diffs: [{ path: "~/code/relay/src/a.ts", oldText: "a\nb\n", newText: "a\nB\n" }],
        },
      },
    ],
  },
] as AcpmuxRow[]);

const wire = (complete = true) => ({
  checkpoint_id: "cp-7",
  complete,
  diff: {
    scope: "lastTurn",
    root: "/Users/me/code/relay",
    files: [
      { path: "src/a.ts", status: "modified", additions: 1, deletions: 1, patch: "@@ -1,2 +1,2 @@\n a\n-b\n+B\n" },
      { path: "src/a.generated.ts", status: "added", additions: 2, deletions: 0, patch: "@@ -0,0 +1,2 @@\n+x\n+y\n" },
    ],
  },
});

describe("turn checkpoint", () => {
  test("reads a pair, a turn without one, an incomplete pair and a malformed answer", () => {
    expect(readTurnCheckpoint(wire())).toMatchObject({ state: "loaded", checkpointId: "cp-7" });
    expect(readTurnCheckpoint(null)).toEqual({ state: "missing" });
    expect(readTurnCheckpoint(wire(false))).toEqual({ state: "incomplete", checkpointId: "cp-7" });
    expect(readTurnCheckpoint({ complete: true })).toEqual({ state: "error" });
  });

  test("a loaded checkpoint replaces the tool calls' edits, marking files no tool call changed", () => {
    const display = turnDisplay(toolFiles, readTurnCheckpoint(wire()), false);
    expect(display.source).toBe("checkpoint");
    expect(display.note).toBeUndefined();
    expect(display.files.map((file) => [file.displayPath, file.outside ?? false])).toEqual([
      ["src/a.ts", false],
      ["src/a.generated.ts", true],
    ]);
    expect(display.files[0]!.edits[0]!.toolId).toBe("checkpoint:cp-7");
    const checkpointHunk = display.files[0]!.edits[0]!.hunks[0]!;
    expect(checkpointHunk.reviewKeys).toEqual([hunkKey(toolFiles[0]!, 0, 0)]);
    expect(checkpointHunk.checkpoint?.key).toBe(checkpointHunkKey("cp-7", display.files[0]!.path, checkpointHunk));
    expect(display.files[1]!.edits[0]!.hunks[0]!.reviewKeys).toEqual([]);
  });

  test("line ranges choose one tool hunk when identical changed text occurs twice", () => {
    const files = turnFiles([
      {
        id: "activity-3",
        version: 1,
        at: 3,
        kind: "activity",
        items: [
          {
            kind: "tool",
            text: "",
            tool: {
              id: "t2",
              title: "Edit",
              kind: "edit",
              status: "completed",
              diffs: [
                { path: "~/code/relay/src/a.ts", oldText: "a\nx\nz\n", newText: "a\nX\nz\n", line: 2 },
                { path: "~/code/relay/src/a.ts", oldText: "a\nx\nz\n", newText: "a\nx\nX\n", line: 3 },
              ],
            },
          },
        ],
      },
    ] as AcpmuxRow[]);
    const display = turnDisplay(
      files,
      readTurnCheckpoint({
        checkpoint_id: "cp-range",
        complete: true,
        diff: {
          files: [
            {
              path: "src/a.ts",
              status: "modified",
              additions: 1,
              deletions: 1,
              patch: "@@ -2,1 +2,1 @@\n-x\n+X\n",
            },
          ],
        },
      }),
      false,
    );
    const keys = display.files[0]!.edits[0]!.hunks[0]!.reviewKeys;
    expect(keys).toEqual([hunkKey(files[0]!, 0, 0)]);
  });

  test("a checkpoint hunk with different changed lines remains read-only", () => {
    const display = turnDisplay(
      toolFiles,
      readTurnCheckpoint({
        ...wire(),
        diff: {
          files: [
            {
              path: "src/a.ts",
              status: "modified",
              additions: 1,
              deletions: 1,
              patch: "@@ -1,2 +1,2 @@\n a\n-b\n+elsewhere\n",
            },
          ],
        },
      }),
      false,
    );
    expect(display.files[0]!.edits[0]!.hunks[0]!.reviewKeys).toEqual([]);
  });

  test("every case without a usable checkpoint shows the tool calls' edits, with a note when one was expected", () => {
    const cases: [TurnCheckpointLoad, boolean][] = [
      [{ state: "unsupported" }, false],
      [{ state: "loading" }, false],
      [{ state: "missing" }, true],
      [{ state: "error", message: "boom" }, true],
      [{ state: "incomplete", checkpointId: "cp-7" }, true],
    ];
    for (const [load, noted] of cases) {
      const display = turnDisplay(toolFiles, load, false);
      expect(display.source).toBe("tools");
      expect(display.files).toBe(toolFiles);
      expect(Boolean(display.note)).toBe(noted);
    }
  });

  test("an unsent Undo holds the tool-call view even after the checkpoint loads", () => {
    const display = turnDisplay(toolFiles, readTurnCheckpoint(wire()), true);
    expect(display.source).toBe("tools");
    expect(display.note).toContain("Keep and Undo");
  });

  test("the card counts the checkpoint once it loads, and the tool calls before", () => {
    expect(turnCounts(toolFiles, undefined)).toMatchObject({ additions: 1, deletions: 1, outside: false });
    expect(turnCounts(toolFiles, { state: "missing" })).toMatchObject({ additions: 1, deletions: 1, outside: false });
    const counts = turnCounts(toolFiles, readTurnCheckpoint(wire()));
    expect(counts).toMatchObject({ additions: 3, deletions: 1, outside: true });
    expect(counts.files).toHaveLength(2);
  });
});
