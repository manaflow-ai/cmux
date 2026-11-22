import { describe, expect, test } from "bun:test";
import {
  diffHunks,
  diffLines,
  editPatch,
  hunkKey,
  hunkPatch,
  rejectionPrompt,
  turnFiles,
  turnRows,
  undoPrompt,
} from "./diff";
import { mergeToolItem, toolDiffs } from "./direct";
import type { AcpmuxRow } from "./model";

const lines = (count: number, prefix = "line") =>
  Array.from({ length: count }, (_, index) => `${prefix} ${index + 1}`).join("\n") + "\n";

describe("line diff", () => {
  test("marks one changed line between unchanged ones", () => {
    expect(diffLines("a\nb\nc\n", "a\nB\nc\n").map((op) => `${op.type}:${op.text}`)).toEqual([
      "context:a",
      "del:b",
      "add:B",
      "context:c",
    ]);
  });

  test("a new file is all additions", () => {
    expect(diffLines(undefined, "x\ny").map((op) => op.type)).toEqual(["add", "add"]);
  });

  test("finds a minimal diff, not a replacement, inside the changed range", () => {
    const ops = diffLines("a\nb\nc\nd\ne\n", "a\nc\nd\nX\ne\n");
    expect(ops.map((op) => `${op.type}:${op.text}`)).toEqual([
      "context:a",
      "del:b",
      "context:c",
      "context:d",
      "add:X",
      "context:e",
    ]);
  });

  test("a rewrite past the step limit falls back to a replacement", () => {
    const ops = diffLines(lines(1500, "old"), lines(1500, "new"));
    expect(ops.filter((op) => op.type === "del").length).toBe(1500);
    expect(ops.filter((op) => op.type === "add").length).toBe(1500);
  });
});

describe("hunks", () => {
  test("keep three lines of context and split distant changes", () => {
    const before = lines(30);
    const after = before.replace("line 5\n", "line five\n").replace("line 25\n", "line twenty-five\n");
    const hunks = diffHunks(diffLines(before, after));
    expect(hunks.length).toBe(2);
    expect(hunks[0].lines[0]).toMatchObject({ type: "context", oldLine: 2, newLine: 2 });
    expect(hunks[0].lines.at(-1)).toMatchObject({ type: "context", oldLine: 8 });
    expect(hunks[1].lines.find((line) => line.type === "add")).toMatchObject({ text: "line twenty-five", newLine: 25 });
  });

  test("number from the edit's first line", () => {
    const [hunk] = diffHunks(diffLines("a\nb\n", "a\nc\n"), 40);
    expect(hunk.lines.map((line) => [line.oldLine, line.newLine])).toEqual([
      [40, 40],
      [41, undefined],
      [undefined, 41],
    ]);
  });
});

const edit = (
  id: string,
  diffs: { path: string; oldText?: string; newText: string; line?: number }[],
): AcpmuxRow["items"] => [
  { kind: "tool", text: id, tool: { id, title: id, kind: "edit", status: "completed", diffs } },
];

describe("turn changes", () => {
  const rows: AcpmuxRow[] = [
    { id: "user-1", version: 1, at: 1, kind: "user", text: "first" },
    {
      id: "activity-2",
      version: 1,
      at: 2,
      kind: "activity",
      items: edit("t1", [{ path: "/repo/src/old.ts", oldText: "a\n", newText: "b\n" }]),
    },
    { id: "user-3", version: 1, at: 3, kind: "user", text: "second" },
    {
      id: "activity-4",
      version: 1,
      at: 4,
      kind: "activity",
      items: [
        ...edit("t2", [{ path: "/repo/src/app/main.ts", oldText: "x\ny\n", newText: "x\nz\n", line: 10 }])!,
        ...edit("t3", [
          { path: "/repo/README.md", newText: "hi\n" },
          { path: "/repo/src/app/main.ts", oldText: "z\n", newText: "w\n" },
        ])!,
      ],
    },
    { id: "assistant-5", version: 1, at: 5, kind: "assistant", text: "done" },
  ];

  test("a turn runs from its user message to the next", () => {
    expect(turnRows(rows, "assistant-5").map((row) => row.id)).toEqual(["user-3", "activity-4", "assistant-5"]);
    expect(turnRows(rows, "activity-2").map((row) => row.id)).toEqual(["user-1", "activity-2"]);
    expect(turnRows(rows, "missing")).toEqual([]);
  });

  test("collects each file once, its edits in order, with paths under their shared directory", () => {
    const files = turnFiles(turnRows(rows, "activity-4"));
    expect(files.map((file) => file.displayPath)).toEqual(["src/app/main.ts", "README.md"]);
    const [main, readme] = files;
    expect(main.edits.map((entry) => entry.toolId)).toEqual(["t2", "t3"]);
    expect(main.edits.map((entry) => entry.numbered)).toEqual([true, false]);
    expect(main.edits[0].hunks[0].lines.find((line) => line.type === "add")?.newLine).toBe(11);
    expect([main.additions, main.deletions]).toEqual([2, 2]);
    expect(readme).toMatchObject({ created: true, additions: 1, deletions: 0 });
  });

  test("each edit becomes a patch Pierre can render, a new file from /dev/null", () => {
    const [main, readme] = turnFiles(turnRows(rows, "activity-4"));
    expect(editPatch(main, main.edits[0])).toBe(
      [
        "diff --git a/src/app/main.ts b/src/app/main.ts",
        "--- a/src/app/main.ts",
        "+++ b/src/app/main.ts",
        "@@ -10,2 +10,2 @@",
        " x",
        "-y",
        "+z",
        "",
      ].join("\n"),
    );
    expect(editPatch(readme, readme.edits[0])).toBe(
      ["diff --git a/README.md b/README.md", "--- /dev/null", "+++ b/README.md", "@@ -0,0 +1,1 @@", "+hi", ""].join(
        "\n",
      ),
    );
  });
});

describe("ACP tool call diffs", () => {
  test("reads diff content and places it by the call's locations", () => {
    expect(
      toolDiffs(
        [
          { type: "content", content: { type: "text", text: "ok" } },
          { type: "diff", path: "/a.ts", oldText: "1", newText: "2" },
          { type: "diff", path: "/b.ts", oldText: null, newText: "new" },
        ],
        [{ path: "/a.ts", line: 7 }],
      ),
    ).toEqual([
      { path: "/a.ts", oldText: "1", newText: "2", line: 7 },
      { path: "/b.ts", oldText: undefined, newText: "new", line: undefined },
    ]);
    expect(toolDiffs([{ type: "content", content: { type: "text", text: "ok" } }], [])).toBeUndefined();
  });

  test("an update with content but no locations keeps the call's line", () => {
    const first = mergeToolItem(
      undefined,
      { toolCallId: "t", kind: "edit", locations: [{ path: "/a.ts", line: 12 }] },
      "t",
      "",
    );
    expect(
      mergeToolItem(
        first,
        { toolCallId: "t", content: [{ type: "diff", path: "/a.ts", oldText: "1", newText: "2" }] },
        "t",
        "",
      ).tool?.diffs?.[0].line,
    ).toBe(12);
    const unplaced = mergeToolItem(
      undefined,
      { toolCallId: "t", kind: "edit", content: [{ type: "diff", path: "/a.ts", oldText: "1", newText: "2" }] },
      "t",
      "",
    );
    expect(
      mergeToolItem(unplaced, { toolCallId: "t", locations: [{ path: "/a.ts", line: 7 }] }, "t", "").tool?.diffs?.[0]
        .line,
    ).toBe(7);
  });

  test("an update without kind or content keeps what the call already had", () => {
    const first = mergeToolItem(
      undefined,
      {
        toolCallId: "t",
        title: "Edit a.ts",
        kind: "edit",
        status: "pending",
        content: [{ type: "diff", path: "/a.ts", oldText: "1", newText: "2" }],
      },
      "t",
      "",
    );
    const updated = mergeToolItem(first, { toolCallId: "t", status: "completed" }, "t", "");
    expect(updated.tool).toMatchObject({ title: "Edit a.ts", kind: "edit", status: "completed" });
    expect(updated.tool?.diffs?.[0].path).toBe("/a.ts");
    // Content in an update replaces the call's content.
    expect(
      mergeToolItem(
        updated,
        { toolCallId: "t", content: [{ type: "content", content: { type: "text", text: "failed" } }] },
        "t",
        "failed",
      ).tool,
    ).toMatchObject({ diffs: undefined, output: "failed", kind: "edit" });
  });
});

describe("highlighted languages", () => {
  test("every language the bundle ships is a Shiki language, and others fall back to text", async () => {
    const { bundledLanguages } = await import("shiki");
    const { getFiletypeFromFileName } = await import("@pierre/diffs");
    const { HIGHLIGHTED_LANGUAGES, isHighlighted } = await import("./shikiLanguages");
    for (const [id, aliases] of Object.entries(HIGHLIGHTED_LANGUAGES))
      for (const name of [id, ...aliases]) expect(name in bundledLanguages).toBe(true);
    expect(
      ["a.ts", "a.tsx", "a.swift", "a.py", "Makefile", "a.md", "a.c"].map((name) =>
        isHighlighted(getFiletypeFromFileName(name)),
      ),
    ).toEqual([true, true, true, true, true, true, true]);
    expect(["a.h", "a.cpp", "a.rb"].map((name) => isHighlighted(getFiletypeFromFileName(name)))).toEqual([
      false,
      false,
      false,
    ]);
  });
});

describe("hunk review", () => {
  const rows: AcpmuxRow[] = [
    { id: "user-1", version: 1, at: 1, kind: "user", text: "go" },
    {
      id: "activity-2",
      version: 1,
      at: 2,
      kind: "activity",
      items: [
        ...edit("t1", [
          { path: "/repo/src/a.ts", oldText: "one\ntwo\nthree\n", newText: "one\n2\nthree\n", line: 10 },
        ])!,
        ...edit("t2", [{ path: "/repo/src/b.ts", oldText: "x\n", newText: "y\n" }])!,
      ],
    },
  ];
  const files = turnFiles(rows);

  test("a numbered hunk carries its ranges", () => {
    const [a] = files;
    expect(hunkPatch(a, a.edits[0], a.edits[0].hunks[0])).toBe(
      ["--- /repo/src/a.ts", "+++ /repo/src/a.ts", "@@ -10,3 +10,3 @@", " one", "-two", "+2", " three"].join("\n"),
    );
  });

  test("a fragment's hunk has no ranges to get wrong", () => {
    const b = files[1];
    expect(hunkPatch(b, b.edits[0], b.edits[0].hunks[0]).split("\n")[2]).toBe("@@");
  });

  test("keys tell hunks apart across tool calls and files", () => {
    expect(hunkKey(files[0], 0, 0)).not.toBe(hunkKey(files[1], 0, 0));
  });

  test("the rejection prompt fences every patch and appends the note", () => {
    const prompt = rejectionPrompt(["P1", "P2"], "  use a constant instead ");
    expect(prompt).toBe(
      [
        "I reviewed your changes and rejected these 2. Please revert them and keep your other changes:",
        "",
        "```diff",
        "P1\nP2",
        "```",
        "",
        "use a constant instead",
      ].join("\n"),
    );
    expect(rejectionPrompt(["+```js"]).split("\n")[2]).toBe("````diff");
    expect(rejectionPrompt(["P"]).startsWith("I reviewed your changes and rejected this one.")).toBe(true);
  });

  test("a turn's Undo asks for every patch in one fence, longer than any backtick run", () => {
    expect(undoPrompt(["P1", "+```js"]).split("\n")).toEqual([
      "Please undo the changes you made in that turn, so these files read as they did before it:",
      "",
      "````diff",
      "P1",
      "+```js",
      "````",
    ]);
  });
});
