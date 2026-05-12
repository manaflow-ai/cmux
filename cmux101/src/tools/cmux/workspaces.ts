/**
 * workspaces.ts — cmux workspace management tools.
 *
 * Covers: list_workspaces, new_workspace, current_workspace,
 *         select_workspace, close_workspace, rename_workspace.
 */

import { z } from "zod";
import type { Tool, ToolResult } from "../../core/types";
import { runCmux } from "./exec";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Return the effective workspace ref: caller-supplied or $CMUX_WORKSPACE_ID. */
function workspaceArg(workspace?: string): string[] {
  const ws = workspace ?? process.env.CMUX_WORKSPACE_ID;
  return ws ? ["--workspace", ws] : [];
}

// ---------------------------------------------------------------------------
// list_workspaces
// ---------------------------------------------------------------------------

export const listWorkspacesTool: Tool = {
  name: "cmux_list_workspaces",
  description:
    "List all workspaces in the current cmux window. Shows each workspace's ref, name, and which is currently selected.",
  inputSchema: z.object({}),
  defaultPermission: "allow",

  async run(): Promise<ToolResult> {
    const { stdout, stderr, exitCode } = await runCmux(["list-workspaces"]);
    if (exitCode !== 0) {
      return { content: stderr || "cmux list-workspaces failed", isError: true };
    }
    return { content: stdout.trim() || "(no workspaces)" };
  },
};

// ---------------------------------------------------------------------------
// new_workspace
// ---------------------------------------------------------------------------

const newWorkspaceSchema = z.object({
  name: z.string().optional().describe("Title for the new workspace"),
  description: z.string().optional().describe("Short description"),
  cwd: z.string().optional().describe("Initial working directory for the workspace shell"),
  command: z.string().optional().describe("Shell command to run in the first terminal surface"),
  focus: z.boolean().optional().describe("Focus the new workspace immediately (default: true)"),
});

export const newWorkspaceTool: Tool = {
  name: "cmux_new_workspace",
  description:
    "Create a new workspace in the current cmux window, optionally with a name, description, starting directory, and an initial command.",
  inputSchema: newWorkspaceSchema,
  defaultPermission: "ask",

  async run(input: unknown): Promise<ToolResult> {
    const parsed = newWorkspaceSchema.parse(input);
    const args: string[] = ["new-workspace"];
    if (parsed.name) args.push("--name", parsed.name);
    if (parsed.description) args.push("--description", parsed.description);
    if (parsed.cwd) args.push("--cwd", parsed.cwd);
    if (parsed.command) args.push("--command", parsed.command);
    if (parsed.focus !== undefined) args.push("--focus", String(parsed.focus));

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux new-workspace failed", isError: true };
    }
    return { content: `Created workspace: ${stdout.trim()}` };
  },
};

// ---------------------------------------------------------------------------
// current_workspace
// ---------------------------------------------------------------------------

export const currentWorkspaceTool: Tool = {
  name: "cmux_current_workspace",
  description:
    "Return the ref (e.g. workspace:5) of the workspace that is currently selected/focused.",
  inputSchema: z.object({}),
  defaultPermission: "allow",

  async run(): Promise<ToolResult> {
    const { stdout, stderr, exitCode } = await runCmux(["current-workspace"]);
    if (exitCode !== 0) {
      return { content: stderr || "cmux current-workspace failed", isError: true };
    }
    return { content: stdout.trim() };
  },
};

// ---------------------------------------------------------------------------
// select_workspace
// ---------------------------------------------------------------------------

const selectWorkspaceSchema = z.object({
  workspace: z
    .string()
    .describe("Workspace ref, UUID, or index to select (e.g. workspace:2, workspace:1)"),
});

export const selectWorkspaceTool: Tool = {
  name: "cmux_select_workspace",
  description:
    "Switch focus to a different workspace by ref, UUID, or index.",
  inputSchema: selectWorkspaceSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { workspace } = selectWorkspaceSchema.parse(input);
    const { stdout, stderr, exitCode } = await runCmux([
      "select-workspace",
      "--workspace",
      workspace,
    ]);
    if (exitCode !== 0) {
      return { content: stderr || "cmux select-workspace failed", isError: true };
    }
    return { content: stdout.trim() || `Selected workspace ${workspace}` };
  },
};

// ---------------------------------------------------------------------------
// close_workspace
// ---------------------------------------------------------------------------

const closeWorkspaceSchema = z.object({
  workspace: z
    .string()
    .optional()
    .describe(
      "Workspace ref, UUID, or index to close. Defaults to $CMUX_WORKSPACE_ID if set.",
    ),
});

export const closeWorkspaceTool: Tool = {
  name: "cmux_close_workspace",
  description:
    "Close a workspace and all its panes/surfaces. Destructive — confirm before use.",
  inputSchema: closeWorkspaceSchema,
  defaultPermission: "ask",

  async run(input: unknown): Promise<ToolResult> {
    const { workspace } = closeWorkspaceSchema.parse(input);
    const args = ["close-workspace", ...workspaceArg(workspace)];
    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux close-workspace failed", isError: true };
    }
    return { content: stdout.trim() || `Closed workspace ${workspace ?? "(current)"}` };
  },
};

// ---------------------------------------------------------------------------
// rename_workspace
// ---------------------------------------------------------------------------

const renameWorkspaceSchema = z.object({
  title: z.string().describe("New name for the workspace"),
  workspace: z
    .string()
    .optional()
    .describe(
      "Workspace ref, UUID, or index. Defaults to $CMUX_WORKSPACE_ID if set.",
    ),
});

export const renameWorkspaceTool: Tool = {
  name: "cmux_rename_workspace",
  description: "Rename a workspace. Defaults to the current workspace.",
  inputSchema: renameWorkspaceSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { title, workspace } = renameWorkspaceSchema.parse(input);
    const args = ["rename-workspace", ...workspaceArg(workspace), title];
    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux rename-workspace failed", isError: true };
    }
    return { content: stdout.trim() || `Renamed workspace to "${title}"` };
  },
};

export const workspaceTools: Tool[] = [
  listWorkspacesTool,
  currentWorkspaceTool,
  selectWorkspaceTool,
  newWorkspaceTool,
  closeWorkspaceTool,
  renameWorkspaceTool,
];
