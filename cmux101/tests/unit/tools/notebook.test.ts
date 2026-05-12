import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import * as path from "node:path";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import { notebookEditTool } from "../../../src/tools/notebook";
import type { ToolContext, PermissionLevel } from "../../../src/core/types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeCtx(cwd: string, permissionLevel: PermissionLevel = "allow"): ToolContext {
  return {
    cwd,
    abortSignal: new AbortController().signal,
    log: (_level, _text) => {},
    permissions: {
      resolve: (_toolName: string, _input: unknown) => permissionLevel,
      remember: () => {},
      narrow: (_allowedTools: string[]) => makeCtx(cwd, permissionLevel).permissions,
    },
    session: {
      meta: {
        id: "test",
        cwd,
        startedAt: new Date().toISOString(),
        providerId: "test",
        model: "test",
      },
      messages: [],
      append: async () => {},
      recordEvent: async () => {},
    },
    spawnSubagent: async () => ({
      text: "",
      usage: { inputTokens: 0, outputTokens: 0 },
      transcriptPath: "",
      ok: false,
    }),
    toolRegistry: {
      get: () => undefined,
      list: () => [],
      toSchemas: () => [],
    },
    emitHook: async () => ({ action: "pass" }),
  };
}

function makeNotebook(cells: Array<{ cell_type: "code" | "markdown"; source: string; id?: string }>) {
  return {
    cells: cells.map((c, i) => ({
      cell_type: c.cell_type,
      source: c.source.split("\n").map((l, li, arr) => li < arr.length - 1 ? l + "\n" : l),
      id: c.id ?? `cell-${i}`,
      outputs: c.cell_type === "code" ? [{ output_type: "stream", text: "old output" }] : undefined,
      execution_count: c.cell_type === "code" ? 5 : undefined,
      metadata: {},
    })),
    metadata: { kernelspec: { name: "python3" } },
    nbformat: 4,
    nbformat_minor: 5,
  };
}

let tmpDir: string;

beforeEach(async () => {
  tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "cmux101-nb-test-"));
});

afterEach(async () => {
  await fs.rm(tmpDir, { recursive: true, force: true });
});

async function writeNotebook(filePath: string, nb: object): Promise<void> {
  await Bun.write(filePath, JSON.stringify(nb, null, 1));
}

async function readNotebook(filePath: string) {
  return JSON.parse(await Bun.file(filePath).text());
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("notebook_edit — replace", () => {
  test("replaces cell source by index, clears outputs and execution_count", async () => {
    const nbPath = path.join(tmpDir, "test.ipynb");
    await writeNotebook(nbPath, makeNotebook([
      { cell_type: "code", source: "x = 1", id: "cell-a" },
      { cell_type: "markdown", source: "# Title" },
    ]));

    const ctx = makeCtx(tmpDir);
    const result = await (notebookEditTool.run as Function)(
      { notebook_path: nbPath, cell_index: 0, source: "x = 42" },
      ctx
    );

    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("index 0");

    const nb = await readNotebook(nbPath);
    const cell = nb.cells[0];
    // Source updated
    const source = Array.isArray(cell.source) ? cell.source.join("") : cell.source;
    expect(source).toBe("x = 42");
    // Outputs cleared
    expect(cell.outputs).toEqual([]);
    expect(cell.execution_count).toBeNull();
  });

  test("replaces cell source by cell_id", async () => {
    const nbPath = path.join(tmpDir, "test.ipynb");
    await writeNotebook(nbPath, makeNotebook([
      { cell_type: "code", source: "old code", id: "my-cell" },
    ]));

    const ctx = makeCtx(tmpDir);
    const result = await (notebookEditTool.run as Function)(
      { notebook_path: nbPath, cell_id: "my-cell", source: "new code" },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const nb = await readNotebook(nbPath);
    const source = Array.isArray(nb.cells[0].source)
      ? nb.cells[0].source.join("")
      : nb.cells[0].source;
    expect(source).toBe("new code");
  });
});

describe("notebook_edit — insert", () => {
  test("inserts a new code cell at a given index", async () => {
    const nbPath = path.join(tmpDir, "test.ipynb");
    await writeNotebook(nbPath, makeNotebook([
      { cell_type: "code", source: "first" },
      { cell_type: "code", source: "second" },
    ]));

    const ctx = makeCtx(tmpDir);
    const result = await (notebookEditTool.run as Function)(
      {
        notebook_path: nbPath,
        cell_index: 1,
        cell_type: "code",
        source: "inserted",
        edit_mode: "insert",
      },
      ctx
    );

    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("index 1");

    const nb = await readNotebook(nbPath);
    expect(nb.cells).toHaveLength(3);
    const insertedSource = Array.isArray(nb.cells[1].source)
      ? nb.cells[1].source.join("")
      : nb.cells[1].source;
    expect(insertedSource).toBe("inserted");
    expect(nb.cells[1].outputs).toEqual([]);
    expect(nb.cells[1].execution_count).toBeNull();
  });

  test("appends a markdown cell when no index given", async () => {
    const nbPath = path.join(tmpDir, "test.ipynb");
    await writeNotebook(nbPath, makeNotebook([
      { cell_type: "code", source: "x = 1" },
    ]));

    const ctx = makeCtx(tmpDir);
    const result = await (notebookEditTool.run as Function)(
      {
        notebook_path: nbPath,
        cell_type: "markdown",
        source: "## New Section",
        edit_mode: "insert",
      },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const nb = await readNotebook(nbPath);
    expect(nb.cells).toHaveLength(2);
    expect(nb.cells[1].cell_type).toBe("markdown");
  });

  test("errors when cell_type missing for insert", async () => {
    const nbPath = path.join(tmpDir, "test.ipynb");
    await writeNotebook(nbPath, makeNotebook([]));

    const ctx = makeCtx(tmpDir);
    const result = await (notebookEditTool.run as Function)(
      { notebook_path: nbPath, source: "x = 1", edit_mode: "insert" },
      ctx
    );

    expect(result.isError).toBe(true);
    expect(result.content).toContain("cell_type");
  });
});

describe("notebook_edit — delete", () => {
  test("deletes a cell by index", async () => {
    const nbPath = path.join(tmpDir, "test.ipynb");
    await writeNotebook(nbPath, makeNotebook([
      { cell_type: "code", source: "keep me" },
      { cell_type: "markdown", source: "delete me" },
    ]));

    const ctx = makeCtx(tmpDir);
    const result = await (notebookEditTool.run as Function)(
      { notebook_path: nbPath, cell_index: 1, source: "", edit_mode: "delete" },
      ctx
    );

    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("Deleted");
    const nb = await readNotebook(nbPath);
    expect(nb.cells).toHaveLength(1);
    const s = Array.isArray(nb.cells[0].source)
      ? nb.cells[0].source.join("")
      : nb.cells[0].source;
    expect(s).toBe("keep me");
  });

  test("deletes a cell by cell_id", async () => {
    const nbPath = path.join(tmpDir, "test.ipynb");
    await writeNotebook(nbPath, makeNotebook([
      { cell_type: "code", source: "a", id: "keep" },
      { cell_type: "code", source: "b", id: "remove" },
    ]));

    const ctx = makeCtx(tmpDir);
    const result = await (notebookEditTool.run as Function)(
      { notebook_path: nbPath, cell_id: "remove", source: "", edit_mode: "delete" },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const nb = await readNotebook(nbPath);
    expect(nb.cells).toHaveLength(1);
    expect(nb.cells[0].id).toBe("keep");
  });
});

describe("notebook_edit — error cases", () => {
  test("returns error for missing notebook", async () => {
    const ctx = makeCtx(tmpDir);
    const result = await (notebookEditTool.run as Function)(
      { notebook_path: path.join(tmpDir, "nonexistent.ipynb"), cell_index: 0, source: "x" },
      ctx
    );
    expect(result.isError).toBe(true);
    expect(result.content).toContain("not found");
  });

  test("returns error for out-of-bounds cell_index", async () => {
    const nbPath = path.join(tmpDir, "test.ipynb");
    await writeNotebook(nbPath, makeNotebook([{ cell_type: "code", source: "x" }]));

    const ctx = makeCtx(tmpDir);
    const result = await (notebookEditTool.run as Function)(
      { notebook_path: nbPath, cell_index: 99, source: "y" },
      ctx
    );
    expect(result.isError).toBe(true);
    expect(result.content).toContain("not found");
  });

  test("returns error for unknown cell_id", async () => {
    const nbPath = path.join(tmpDir, "test.ipynb");
    await writeNotebook(nbPath, makeNotebook([{ cell_type: "code", source: "x", id: "real-id" }]));

    const ctx = makeCtx(tmpDir);
    const result = await (notebookEditTool.run as Function)(
      { notebook_path: nbPath, cell_id: "bogus-id", source: "y" },
      ctx
    );
    expect(result.isError).toBe(true);
    expect(result.content).toContain("not found");
  });
});
