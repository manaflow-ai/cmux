/**
 * index.ts — cmux integration tool pack entry point.
 *
 * Exports:
 *   cmuxToolPack   — ordered array of all cmux Tool objects.
 *   cmuxAvailable  — async predicate; true if cmux is installed and reachable.
 */

import type { Tool } from "../../core/types";
import { runCmux } from "./exec";

import { treeTools } from "./tree";
import { ioTools } from "./io";
import { paneTools } from "./panes";
import { workspaceTools } from "./workspaces";
import { notifyTools } from "./notify";
import { browserTools } from "./browser";
import { rawTool } from "./raw";

/**
 * All cmux tools, ordered by usefulness in an agentic coding workflow.
 *
 * High-value tools first (tree, send, new_pane, read_screen, browser_navigate),
 * then workspace management, notify/status, and the raw escape hatch last.
 */
export const cmuxToolPack: Tool[] = [
  // Orientation: see the full workspace+pane hierarchy at a glance.
  ...treeTools,           // cmux_tree, cmux_top

  // Core I/O: send commands and read output from terminal surfaces.
  ...ioTools,             // cmux_send, cmux_send_key, cmux_read_screen

  // Pane management: create splits, list panes, focus and close surfaces.
  ...paneTools,           // cmux_list_panes, cmux_new_pane, cmux_new_split, cmux_focus_pane, cmux_close_surface

  // Browser automation: navigate pages, snapshot, click, type, screenshot.
  ...browserTools,        // cmux_browser_navigate, cmux_browser_snapshot, ...

  // Workspace management: list, select, create, rename, close workspaces.
  ...workspaceTools,      // cmux_list_workspaces, cmux_current_workspace, ...

  // Notifications and status: surface progress and events to the user.
  ...notifyTools,         // cmux_notify, cmux_set_status, cmux_set_progress, cmux_log

  // Escape hatch: run any cmux subcommand directly (requires user approval).
  rawTool,                // cmux_raw
];

/**
 * Returns true if cmux is installed and the daemon is reachable.
 *
 * Runs `cmux --version` with a 2s timeout. Suitable as an `available`
 * predicate on every tool in cmuxToolPack.
 */
export async function cmuxAvailable(): Promise<boolean> {
  try {
    const { exitCode } = await runCmux(["--version"], { timeoutMs: 2_000 });
    return exitCode === 0;
  } catch {
    return false;
  }
}

// Re-export individual group tools and helpers for fine-grained imports.
export { treeTools } from "./tree";
export { ioTools } from "./io";
export { paneTools } from "./panes";
export { workspaceTools } from "./workspaces";
export { notifyTools } from "./notify";
export { browserTools } from "./browser";
export { rawTool } from "./raw";
export { runCmux } from "./exec";
