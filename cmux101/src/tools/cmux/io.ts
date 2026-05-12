/**
 * io.ts — cmux terminal I/O tools.
 *
 * Covers: send (text to a workspace/surface), send_key (named keys),
 *         read_screen (capture terminal contents).
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
// send
// ---------------------------------------------------------------------------

const sendSchema = z.object({
  text: z.string().describe("Text to send to the terminal. Literal characters only — no key sequences."),
  workspace: z
    .string()
    .optional()
    .describe("Workspace ref/UUID/index. Defaults to $CMUX_WORKSPACE_ID."),
  surface: z
    .string()
    .optional()
    .describe("Surface ref/UUID/index. Defaults to $CMUX_SURFACE_ID."),
});

export const sendTool: Tool = {
  name: "cmux_send",
  description:
    "Send literal text to a terminal surface (as if typed). Does NOT press Enter — append \\n or use cmux_send_key to submit. Great for typing commands into a specific pane without taking focus.",
  inputSchema: sendSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { text, workspace, surface } = sendSchema.parse(input);
    const args = [
      "send",
      ...workspaceArg(workspace),
      ...surfaceArg(surface),
      text,
    ];
    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux send failed", isError: true };
    }
    return { content: stdout.trim() || `Sent text to surface` };
  },
};

// ---------------------------------------------------------------------------
// send_key
// ---------------------------------------------------------------------------

const sendKeySchema = z.object({
  key: z
    .string()
    .describe(
      "Named key to send, e.g. Enter, Tab, Escape, ctrl+c, ctrl+d, Up, Down, Left, Right.",
    ),
  workspace: z
    .string()
    .optional()
    .describe("Workspace ref/UUID/index. Defaults to $CMUX_WORKSPACE_ID."),
  surface: z
    .string()
    .optional()
    .describe("Surface ref/UUID/index. Defaults to $CMUX_SURFACE_ID."),
});

export const sendKeyTool: Tool = {
  name: "cmux_send_key",
  description:
    "Send a named key event to a terminal surface (Enter, Tab, Escape, ctrl+c, ctrl+d, arrow keys, etc.).",
  inputSchema: sendKeySchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { key, workspace, surface } = sendKeySchema.parse(input);
    const args = [
      "send-key",
      ...workspaceArg(workspace),
      ...surfaceArg(surface),
      key,
    ];
    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux send-key failed", isError: true };
    }
    return { content: stdout.trim() || `Sent key: ${key}` };
  },
};

// ---------------------------------------------------------------------------
// read_screen
// ---------------------------------------------------------------------------

const readScreenSchema = z.object({
  workspace: z
    .string()
    .optional()
    .describe("Workspace ref/UUID/index. Defaults to $CMUX_WORKSPACE_ID."),
  surface: z
    .string()
    .optional()
    .describe("Surface ref/UUID/index. Defaults to $CMUX_SURFACE_ID."),
  scrollback: z
    .boolean()
    .optional()
    .describe("Include scrollback buffer above the visible viewport"),
  lines: z
    .number()
    .int()
    .positive()
    .optional()
    .describe("Maximum number of lines to return from the bottom of the buffer"),
});

export const readScreenTool: Tool = {
  name: "cmux_read_screen",
  description:
    "Capture the current visible contents (and optionally scrollback) of a terminal surface. Returns a plain-text snapshot — useful to check what a command printed.",
  inputSchema: readScreenSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { workspace, surface, scrollback, lines } = readScreenSchema.parse(input);
    const args: string[] = ["read-screen"];
    args.push(...workspaceArg(workspace));
    args.push(...surfaceArg(surface));
    if (scrollback) args.push("--scrollback");
    if (lines !== undefined) args.push("--lines", String(lines));

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux read-screen failed", isError: true };
    }

    const screenLines = stdout.split("\n");
    const header = [
      `workspace: ${workspace ?? process.env.CMUX_WORKSPACE_ID ?? "(default)"}`,
      `surface: ${surface ?? process.env.CMUX_SURFACE_ID ?? "(default)"}`,
      `lines: ${screenLines.length}`,
      "---",
    ].join("\n");

    return { content: `${header}\n${stdout}` };
  },
};

export const ioTools: Tool[] = [sendTool, sendKeyTool, readScreenTool];
