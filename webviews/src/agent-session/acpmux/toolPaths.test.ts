// The paths a file tool call edits, from every harness's tool input shape (EditedFilesCard rows).
import { describe, expect, test } from "bun:test";
import { editedPaths, toolLabel } from "./toolPaths";
import type { AcpmuxActivity } from "./model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const call = (title: string, input: unknown, fields: Partial<Tool> = {}): Tool => ({
  id: "t",
  title,
  kind: "edit",
  status: "completed",
  inputSummary: typeof input === "string" ? input : JSON.stringify(input),
  ...fields,
});

describe("editedPaths", () => {
  test("Claude Code Write, Edit, MultiEdit and NotebookEdit", () => {
    expect(editedPaths(call("Write", { content: "import json", file_path: "/tmp/fleetviz/gen.py" }))).toEqual([
      "/tmp/fleetviz/gen.py",
    ]);
    expect(editedPaths(call("Edit", { file_path: "/a/b.ts", old_string: "x", new_string: "y" }))).toEqual(["/a/b.ts"]);
    expect(editedPaths(call("MultiEdit", { edits: [{ old_string: "a" }], file_path: "/a/c.ts" }))).toEqual(["/a/c.ts"]);
    expect(editedPaths(call("NotebookEdit", { new_source: "x", notebook_path: "/a/n.ipynb" }))).toEqual(["/a/n.ipynb"]);
  });

  test("Codex apply_patch and file changes", () => {
    const patch =
      "*** Begin Patch\n*** Update File: src/a.ts\n@@\n-x\n+y\n*** Add File: src/b.ts\n+z\n*** Delete File: src/c.ts\n*** End Patch";
    expect(editedPaths(call("apply_patch", { patch }))).toEqual(["src/a.ts", "src/b.ts", "src/c.ts"]);
    expect(editedPaths(call("apply_patch", { input: patch }))).toEqual(["src/a.ts", "src/b.ts", "src/c.ts"]);
    expect(editedPaths(call("apply_patch", { command: ["apply_patch", patch] }))).toEqual([
      "src/a.ts",
      "src/b.ts",
      "src/c.ts",
    ]);
    expect(
      editedPaths(
        call("Edit files", { changes: { "/w/x.ts": { type: "update" }, "/w/y.ts": { add: { content: "" } } } }),
      ),
    ).toEqual(["/w/x.ts", "/w/y.ts"]);
    expect(
      editedPaths(call("Edit files", { changes: [{ path: "/w/x.ts", kind: "update" }, { path: "/w/z.ts" }] })),
    ).toEqual(["/w/x.ts", "/w/z.ts"]);
  });

  test("opencode, pi and Gemini", () => {
    expect(editedPaths(call("write", { content: "x", filePath: "/o/a.ts" }))).toEqual(["/o/a.ts"]);
    expect(editedPaths(call("edit", { filePath: "/o/b.ts", oldString: "a", newString: "b" }))).toEqual(["/o/b.ts"]);
    expect(
      editedPaths(call("patch", { patchText: "*** Begin Patch\n*** Add File: /o/c.ts\n+x\n*** End Patch" })),
    ).toEqual(["/o/c.ts"]);
    expect(editedPaths(call("write", { content: "x", path: "/p/a.md" }))).toEqual(["/p/a.md"]);
    expect(editedPaths(call("edit", { path: "/p/b.md", oldText: "a", newText: "b" }))).toEqual(["/p/b.md"]);
    expect(editedPaths(call("WriteFile", { absolute_path: "/g/a.ts", content: "x" }))).toEqual(["/g/a.ts"]);
  });

  test("locations, a truncated input and the title are fallbacks; nothing found is empty", () => {
    expect(editedPaths(call("Write", "{}", { locations: [{ path: "/l/a.ts" }] }))).toEqual(["/l/a.ts"]);
    expect(editedPaths(call("Write", '{"content":"import json, sys\\n…","file_path":"/tmp/fleetviz/gen.py"'))).toEqual([
      "/tmp/fleetviz/gen.py",
    ]);
    expect(editedPaths(call("Write /tmp/fleetviz/gen.py", undefined, { inputSummary: undefined }))).toEqual([
      "/tmp/fleetviz/gen.py",
    ]);
    expect(editedPaths(call("Edit `src/a.ts`", "{}"))).toEqual(["src/a.ts"]);
    expect(editedPaths(call("Write", '{"content":"import json, sys, urllib.request'))).toEqual([]);
    expect(editedPaths(call("e1", undefined, { inputSummary: undefined }))).toEqual([]);
  });
});

describe("toolLabel", () => {
  const ran = (command: string) => `Ran ${command}`;

  test("uses a Write path instead of showing its full raw input", () => {
    const tool = call("", { content: "print('hello')", file_path: "gen.py" });
    expect(toolLabel(tool, "Write", ran)).toBe("Write gen.py");
  });

  test("labels commands and reads, then falls back to the tool name", () => {
    expect(toolLabel(call("", { command: "bun test" }, { kind: "execute", command: "bun test" }), "Run", ran)).toBe(
      "Ran bun test",
    );
    expect(toolLabel(call("", { file_path: "src/main.ts" }, { kind: "read" }), "Read", ran)).toBe("Read src/main.ts");
    expect(toolLabel(call("mcp.cua_repl", { apps: [] }, { kind: "execute" }), "mcp.cua_repl", ran)).toBe(
      "mcp.cua_repl",
    );
  });
});
