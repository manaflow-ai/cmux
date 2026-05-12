/**
 * notify.ts — cmux notification and status tools.
 *
 * Covers: notify, set_status, set_progress, log.
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

// ---------------------------------------------------------------------------
// notify
// ---------------------------------------------------------------------------

const notifySchema = z.object({
  title: z.string().describe("Notification title (required)"),
  subtitle: z.string().optional().describe("Subtitle line below the title"),
  body: z.string().optional().describe("Body text of the notification"),
  workspace: z
    .string()
    .optional()
    .describe("Workspace to associate the notification with. Defaults to $CMUX_WORKSPACE_ID."),
  surface: z
    .string()
    .optional()
    .describe("Surface to associate the notification with. Defaults to $CMUX_SURFACE_ID."),
});

export const notifyTool: Tool = {
  name: "cmux_notify",
  description:
    "Send a macOS system notification from cmux. Use to surface important events to the user (build finished, test failed, etc.) without interrupting terminal flow.",
  inputSchema: notifySchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { title, subtitle, body, workspace, surface } = notifySchema.parse(input);
    const args: string[] = ["notify", "--title", title];
    if (subtitle) args.push("--subtitle", subtitle);
    if (body) args.push("--body", body);
    args.push(...workspaceArg(workspace));
    const s = surface ?? process.env.CMUX_SURFACE_ID;
    if (s) args.push("--surface", s);

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux notify failed", isError: true };
    }
    return { content: stdout.trim() || `Notification sent: "${title}"` };
  },
};

// ---------------------------------------------------------------------------
// set_status
// ---------------------------------------------------------------------------

const setStatusSchema = z.object({
  key: z.string().describe("Unique key for this status entry (used to update/clear it later)"),
  value: z.string().describe("Status text to display in the workspace status bar"),
  workspace: z
    .string()
    .optional()
    .describe("Workspace to update. Defaults to $CMUX_WORKSPACE_ID."),
  icon: z
    .string()
    .optional()
    .describe("SF Symbol name to show alongside the status (e.g. 'checkmark.circle')"),
  color: z
    .string()
    .optional()
    .describe("Hex color for the status label (e.g. #ff3b30)"),
});

export const setStatusTool: Tool = {
  name: "cmux_set_status",
  description:
    "Set a named status entry in the cmux workspace status bar. Great for showing agent progress (e.g. 'Building…', 'Tests: 3/10'). Update by calling with the same key.",
  inputSchema: setStatusSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { key, value, workspace, icon, color } = setStatusSchema.parse(input);
    const args: string[] = ["set-status", key, value, ...workspaceArg(workspace)];
    if (icon) args.push("--icon", icon);
    if (color) args.push("--color", color);

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux set-status failed", isError: true };
    }
    return { content: stdout.trim() || `Status[${key}] = "${value}"` };
  },
};

// ---------------------------------------------------------------------------
// set_progress
// ---------------------------------------------------------------------------

const setProgressSchema = z.object({
  progress: z
    .number()
    .min(0)
    .max(1)
    .describe("Progress value between 0.0 (start) and 1.0 (complete)"),
  label: z.string().optional().describe("Optional label shown alongside the progress bar"),
  workspace: z
    .string()
    .optional()
    .describe("Workspace to update. Defaults to $CMUX_WORKSPACE_ID."),
});

export const setProgressTool: Tool = {
  name: "cmux_set_progress",
  description:
    "Update the progress indicator for a workspace (0.0 to 1.0). Useful for long-running tasks like builds or test runs.",
  inputSchema: setProgressSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { progress, label, workspace } = setProgressSchema.parse(input);
    const args: string[] = ["set-progress", String(progress), ...workspaceArg(workspace)];
    if (label) args.push("--label", label);

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux set-progress failed", isError: true };
    }
    return { content: stdout.trim() || `Progress set to ${Math.round(progress * 100)}%` };
  },
};

// ---------------------------------------------------------------------------
// log
// ---------------------------------------------------------------------------

const logSchema = z.object({
  message: z.string().describe("Log message to emit"),
  level: z
    .enum(["debug", "info", "warn", "error"])
    .optional()
    .describe("Log level (default: info)"),
  source: z
    .string()
    .optional()
    .describe("Source label to tag the log entry with (e.g. the tool or agent name)"),
  workspace: z
    .string()
    .optional()
    .describe("Workspace context for the log entry. Defaults to $CMUX_WORKSPACE_ID."),
});

export const logTool: Tool = {
  name: "cmux_log",
  description:
    "Emit a structured log entry into cmux's agent feed. Useful for debugging or leaving a trail of agent actions visible in the cmux feed panel.",
  inputSchema: logSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { message, level, source, workspace } = logSchema.parse(input);
    const args: string[] = ["log", ...workspaceArg(workspace)];
    if (level) args.push("--level", level);
    if (source) args.push("--source", source);
    args.push(message);

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux log failed", isError: true };
    }
    return { content: stdout.trim() || `Logged: ${message}` };
  },
};

export const notifyTools: Tool[] = [notifyTool, setStatusTool, setProgressTool, logTool];
