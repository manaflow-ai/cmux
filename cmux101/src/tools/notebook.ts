/**
 * notebook_edit tool — edit a Jupyter notebook (.ipynb) cell.
 */

import { z } from "zod";
import * as path from "node:path";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import type { Tool, ToolContext, ToolResult } from "../core/types";

// ---------------------------------------------------------------------------
// Jupyter notebook shape (minimal)
// ---------------------------------------------------------------------------

interface JupyterCell {
  cell_type: "code" | "markdown" | "raw";
  source: string | string[];
  id?: string;
  outputs?: unknown[];
  execution_count?: number | null;
  metadata?: Record<string, unknown>;
}

interface JupyterNotebook {
  cells: JupyterCell[];
  metadata: Record<string, unknown>;
  nbformat: number;
  nbformat_minor: number;
}

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

const inputSchema = z.object({
  notebook_path: z.string(),
  cell_id: z.string().optional(),
  cell_index: z.number().int().nonnegative().optional(),
  cell_type: z.enum(["code", "markdown"]).optional(),
  source: z.string(),
  edit_mode: z.enum(["replace", "insert", "delete"]).optional(),
});

type NotebookInput = z.infer<typeof inputSchema>;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function sourceToArray(source: string): string[] {
  if (source === "") return [];
  const lines = source.split("\n");
  return lines.map((line, i) => (i < lines.length - 1 ? line + "\n" : line));
}

function findCellIndex(
  cells: JupyterCell[],
  cell_id?: string,
  cell_index?: number
): number {
  if (cell_id !== undefined) {
    const idx = cells.findIndex((c) => c.id === cell_id);
    return idx;
  }
  if (cell_index !== undefined) {
    return cell_index;
  }
  return -1;
}

function clearCodeCell(cell: JupyterCell): void {
  if (cell.cell_type === "code") {
    cell.outputs = [];
    cell.execution_count = null;
  }
}

// ---------------------------------------------------------------------------
// Tool implementation
// ---------------------------------------------------------------------------

async function runNotebookEdit(
  input: NotebookInput,
  ctx: ToolContext
): Promise<ToolResult> {
  if (ctx.abortSignal.aborted) {
    return { content: "Aborted.", isError: true };
  }

  const resolved = path.isAbsolute(input.notebook_path)
    ? input.notebook_path
    : path.resolve(ctx.cwd, input.notebook_path);

  // Read notebook
  const file = Bun.file(resolved);
  const exists = await file.exists();
  if (!exists) {
    return { content: `Notebook not found: ${resolved}`, isError: true };
  }

  let notebook: JupyterNotebook;
  try {
    const text = await file.text();
    notebook = JSON.parse(text) as JupyterNotebook;
  } catch (err) {
    return { content: `Failed to parse notebook: ${String(err)}`, isError: true };
  }

  const mode = input.edit_mode ?? "replace";

  if (mode === "insert") {
    // Insert new cell
    if (!input.cell_type) {
      return { content: "cell_type is required for insert mode", isError: true };
    }
    const newCell: JupyterCell = {
      cell_type: input.cell_type,
      source: sourceToArray(input.source),
      metadata: {},
    };
    if (input.cell_type === "code") {
      newCell.outputs = [];
      newCell.execution_count = null;
    }

    const insertAt =
      input.cell_index !== undefined
        ? input.cell_index
        : notebook.cells.length;

    const clampedIdx = Math.min(insertAt, notebook.cells.length);
    notebook.cells.splice(clampedIdx, 0, newCell);

    const result = await writeNotebook(resolved, notebook);
    if (result) return result;

    return {
      content: `Inserted ${input.cell_type} cell at index ${clampedIdx}. Notebook now has ${notebook.cells.length} cells.`,
    };
  }

  // For replace/delete we need to find the cell
  if (input.cell_id === undefined && input.cell_index === undefined) {
    if (mode === "replace" || mode === "delete") {
      return {
        content: "Must provide cell_id or cell_index for replace/delete",
        isError: true,
      };
    }
  }

  const idx = findCellIndex(notebook.cells, input.cell_id, input.cell_index);

  if (idx < 0 || idx >= notebook.cells.length) {
    const specifier =
      input.cell_id !== undefined
        ? `cell_id "${input.cell_id}"`
        : `cell_index ${input.cell_index}`;
    return {
      content: `Cell not found: ${specifier} (notebook has ${notebook.cells.length} cells)`,
      isError: true,
    };
  }

  if (ctx.abortSignal.aborted) {
    return { content: "Aborted.", isError: true };
  }

  if (mode === "delete") {
    const removed = notebook.cells.splice(idx, 1)[0];
    const writeErr = await writeNotebook(resolved, notebook);
    if (writeErr) return writeErr;
    return {
      content: `Deleted ${removed.cell_type} cell at index ${idx}. Notebook now has ${notebook.cells.length} cells.`,
    };
  }

  // replace
  const cell = notebook.cells[idx];
  const oldType = cell.cell_type;
  if (input.cell_type) {
    cell.cell_type = input.cell_type;
  }
  cell.source = sourceToArray(input.source);
  clearCodeCell(cell);

  const writeErr = await writeNotebook(resolved, notebook);
  if (writeErr) return writeErr;

  return {
    content: `Replaced source of ${oldType} cell at index ${idx}${
      input.cell_id ? ` (id: ${input.cell_id})` : ""
    }. Outputs and execution_count cleared.`,
  };
}

async function writeNotebook(
  notebookPath: string,
  notebook: JupyterNotebook
): Promise<ToolResult | null> {
  const tmpPath = path.join(
    os.tmpdir(),
    `cmux101-nb-${Date.now()}-${Math.random().toString(36).slice(2)}.tmp`
  );
  try {
    await Bun.write(tmpPath, JSON.stringify(notebook, null, 1));
    await fs.rename(tmpPath, notebookPath);
    return null;
  } catch (err) {
    await fs.unlink(tmpPath).catch(() => {});
    return { content: `Failed to write notebook: ${String(err)}`, isError: true };
  }
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

export const notebookEditTool: Tool = {
  name: "notebook_edit",
  description:
    "Edit a Jupyter notebook (.ipynb) cell: replace source, insert a new cell, or delete a cell. Automatically resets outputs and execution_count for modified code cells.",
  inputSchema,
  defaultPermission: "ask",

  async run(input: unknown, ctx: ToolContext): Promise<ToolResult> {
    const parsed = inputSchema.parse(input);
    return runNotebookEdit(parsed, ctx);
  },
};
