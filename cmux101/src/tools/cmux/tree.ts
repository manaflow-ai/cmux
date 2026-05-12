/**
 * tree.ts — cmux workspace/pane snapshot tools.
 *
 * Covers: tree (ASCII hierarchy of all workspaces+panes),
 *         top (live resource usage per surface).
 */

import { z } from "zod";
import type { Tool, ToolResult } from "../../core/types";
import { runCmux } from "./exec";

// ---------------------------------------------------------------------------
// tree
// ---------------------------------------------------------------------------

const treeSchema = z.object({
  all: z
    .boolean()
    .optional()
    .describe("Show all windows, not just the current one"),
  workspace: z
    .string()
    .optional()
    .describe("Limit the tree to a specific workspace ref/UUID/index"),
});

export const treeTool: Tool = {
  name: "cmux_tree",
  description:
    "Print an ASCII tree of all workspaces and panes in the current cmux window. Shows refs, titles, terminal TTYs, and browser URLs at a glance. Use this to orient yourself before working with panes or surfaces.",
  inputSchema: treeSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const parsed = treeSchema.parse(input);
    const args: string[] = ["tree"];
    if (parsed.all) args.push("--all");
    if (parsed.workspace) args.push("--workspace", parsed.workspace);

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux tree failed", isError: true };
    }
    return { content: stdout.trimEnd() };
  },
};

// ---------------------------------------------------------------------------
// top
// ---------------------------------------------------------------------------

const topSchema = z.object({
  all: z
    .boolean()
    .optional()
    .describe("Show all windows, not just the current one"),
  workspace: z
    .string()
    .optional()
    .describe("Limit to a specific workspace ref/UUID/index"),
  processes: z
    .boolean()
    .optional()
    .describe("Include individual process entries, not just aggregate per surface"),
});

export const topTool: Tool = {
  name: "cmux_top",
  description:
    "Show a live-style snapshot of CPU and memory usage for all panes and surfaces. Helpful for identifying which terminal is running a heavy process.",
  inputSchema: topSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const parsed = topSchema.parse(input);
    const args: string[] = ["top"];
    if (parsed.all) args.push("--all");
    if (parsed.workspace) args.push("--workspace", parsed.workspace);
    if (parsed.processes) args.push("--processes");

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux top failed", isError: true };
    }
    return { content: stdout.trimEnd() };
  },
};

export const treeTools: Tool[] = [treeTool, topTool];
