/**
 * panes.ts — cmux pane/surface management tools.
 *
 * Covers: list_panes, new_pane, new_split, focus_pane, close_surface.
 */

import { z } from "zod";
import type { Tool, ToolResult } from "../../core/types";
import { runCmux } from "./exec";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function workspaceArg(workspace?: string): string[] {
  const ws = workspace ?? process.env.CMUX_WORKSPACE_ID;
  return ws ? ["--workspace", ws] : [];
}

function surfaceArg(surface?: string): string[] {
  const s = surface ?? process.env.CMUX_SURFACE_ID;
  return s ? ["--surface", s] : [];
}

// ---------------------------------------------------------------------------
// list_panes
// ---------------------------------------------------------------------------

const listPanesSchema = z.object({
  workspace: z
    .string()
    .optional()
    .describe("Workspace ref/UUID/index to list panes for. Defaults to $CMUX_WORKSPACE_ID."),
});

export const listPanesTool: Tool = {
  name: "cmux_list_panes",
  description:
    "List all panes in a workspace, showing each pane's ref and surface count.",
  inputSchema: listPanesSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { workspace } = listPanesSchema.parse(input);
    const args = ["list-panes", ...workspaceArg(workspace)];
    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux list-panes failed", isError: true };
    }
    return { content: stdout.trim() || "(no panes)" };
  },
};

// ---------------------------------------------------------------------------
// new_pane
// ---------------------------------------------------------------------------

const newPaneSchema = z.object({
  type: z
    .enum(["terminal", "browser"])
    .optional()
    .describe("Surface type for the new pane (default: terminal)"),
  direction: z
    .enum(["left", "right", "up", "down"])
    .optional()
    .describe("Direction to place the pane relative to the current one"),
  workspace: z
    .string()
    .optional()
    .describe("Workspace ref/UUID/index. Defaults to $CMUX_WORKSPACE_ID."),
  url: z
    .string()
    .optional()
    .describe("Initial URL for browser panes"),
  focus: z.boolean().optional().describe("Focus the new pane immediately"),
});

export const newPaneTool: Tool = {
  name: "cmux_new_pane",
  description:
    "Create a new pane (terminal or browser) in a workspace. To split the current view instead, use cmux_new_split.",
  inputSchema: newPaneSchema,
  defaultPermission: "ask",

  async run(input: unknown): Promise<ToolResult> {
    const parsed = newPaneSchema.parse(input);
    const args: string[] = ["new-pane"];
    if (parsed.type) args.push("--type", parsed.type);
    if (parsed.direction) args.push("--direction", parsed.direction);
    args.push(...workspaceArg(parsed.workspace));
    if (parsed.url) args.push("--url", parsed.url);
    if (parsed.focus !== undefined) args.push("--focus", String(parsed.focus));

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux new-pane failed", isError: true };
    }
    return { content: `Created pane: ${stdout.trim()}` };
  },
};

// ---------------------------------------------------------------------------
// new_split
// ---------------------------------------------------------------------------

const newSplitSchema = z.object({
  direction: z
    .enum(["left", "right", "up", "down"])
    .describe("Direction to split the current pane"),
  workspace: z
    .string()
    .optional()
    .describe("Workspace ref/UUID/index. Defaults to $CMUX_WORKSPACE_ID."),
  surface: z
    .string()
    .optional()
    .describe("Surface ref/UUID/index to split from. Defaults to $CMUX_SURFACE_ID."),
  focus: z.boolean().optional().describe("Focus the new split immediately"),
});

export const newSplitTool: Tool = {
  name: "cmux_new_split",
  description:
    "Split the current pane in a given direction (left/right/up/down), creating a new terminal surface alongside the existing one.",
  inputSchema: newSplitSchema,
  defaultPermission: "ask",

  async run(input: unknown): Promise<ToolResult> {
    const parsed = newSplitSchema.parse(input);
    const args: string[] = ["new-split", parsed.direction];
    args.push(...workspaceArg(parsed.workspace));
    args.push(...surfaceArg(parsed.surface));
    if (parsed.focus !== undefined) args.push("--focus", String(parsed.focus));

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux new-split failed", isError: true };
    }
    return { content: `Created split (${parsed.direction}): ${stdout.trim()}` };
  },
};

// ---------------------------------------------------------------------------
// focus_pane
// ---------------------------------------------------------------------------

const focusPaneSchema = z.object({
  pane: z.string().describe("Pane ref, UUID, or index to focus"),
  workspace: z
    .string()
    .optional()
    .describe("Workspace ref/UUID/index. Defaults to $CMUX_WORKSPACE_ID."),
});

export const focusPaneTool: Tool = {
  name: "cmux_focus_pane",
  description: "Move keyboard focus to the specified pane.",
  inputSchema: focusPaneSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { pane, workspace } = focusPaneSchema.parse(input);
    const args = ["focus-pane", "--pane", pane, ...workspaceArg(workspace)];
    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux focus-pane failed", isError: true };
    }
    return { content: stdout.trim() || `Focused pane ${pane}` };
  },
};

// ---------------------------------------------------------------------------
// close_surface
// ---------------------------------------------------------------------------

const closeSurfaceSchema = z.object({
  surface: z
    .string()
    .optional()
    .describe("Surface ref/UUID/index to close. Defaults to $CMUX_SURFACE_ID."),
  workspace: z
    .string()
    .optional()
    .describe("Workspace ref/UUID/index. Defaults to $CMUX_WORKSPACE_ID."),
});

export const closeSurfaceTool: Tool = {
  name: "cmux_close_surface",
  description:
    "Close a terminal or browser surface. Destructive — closes the surface and its associated shell/page.",
  inputSchema: closeSurfaceSchema,
  defaultPermission: "ask",

  async run(input: unknown): Promise<ToolResult> {
    const { surface, workspace } = closeSurfaceSchema.parse(input);
    const args = ["close-surface", ...surfaceArg(surface), ...workspaceArg(workspace)];
    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux close-surface failed", isError: true };
    }
    return { content: stdout.trim() || `Closed surface ${surface ?? "(current)"}` };
  },
};

export const paneTools: Tool[] = [
  listPanesTool,
  newPaneTool,
  newSplitTool,
  focusPaneTool,
  closeSurfaceTool,
];
