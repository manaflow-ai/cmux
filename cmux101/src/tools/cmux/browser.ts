/**
 * browser.ts — cmux browser automation tools.
 *
 * Covers: browser_open, browser_navigate, browser_snapshot,
 *         browser_click, browser_type, browser_screenshot,
 *         browser_get_url, browser_wait.
 */

import { z } from "zod";
import type { Tool, ToolResult } from "../../core/types";
import { runCmux } from "./exec";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function surfaceArg(surface?: string): string[] {
  const s = surface ?? process.env.CMUX_SURFACE_ID;
  return s ? ["--surface", s] : [];
}

// ---------------------------------------------------------------------------
// browser_open
// ---------------------------------------------------------------------------

const browserOpenSchema = z.object({
  url: z.string().optional().describe("URL to open (omit to open a blank browser panel)"),
  surface: z
    .string()
    .optional()
    .describe(
      "Surface ref/UUID/index. If supplied, behaves like navigate rather than opening a new split.",
    ),
  focus: z.boolean().optional().describe("Focus the browser pane after opening"),
});

export const browserOpenTool: Tool = {
  name: "cmux_browser_open",
  description:
    "Open a browser panel as a new split in the current workspace. Optionally loads a URL and focuses the pane.",
  inputSchema: browserOpenSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { url, surface, focus } = browserOpenSchema.parse(input);
    const args: string[] = ["browser", ...surfaceArg(surface), "open"];
    if (url) args.push(url);
    if (focus !== undefined) args.push("--focus", String(focus));

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux browser open failed", isError: true };
    }
    return { content: stdout.trim() || `Browser opened${url ? `: ${url}` : ""}` };
  },
};

// ---------------------------------------------------------------------------
// browser_navigate
// ---------------------------------------------------------------------------

const browserNavigateSchema = z.object({
  url: z.string().describe("URL to navigate to"),
  surface: z
    .string()
    .optional()
    .describe("Browser surface ref/UUID/index. Defaults to $CMUX_SURFACE_ID."),
  snapshot_after: z
    .boolean()
    .optional()
    .describe("Return an accessibility snapshot after navigation completes"),
});

export const browserNavigateTool: Tool = {
  name: "cmux_browser_navigate",
  description:
    "Navigate an existing browser surface to a URL. Use cmux_browser_open to create the panel first if needed.",
  inputSchema: browserNavigateSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { url, surface, snapshot_after } = browserNavigateSchema.parse(input);
    const args: string[] = ["browser", ...surfaceArg(surface), "navigate", url];
    if (snapshot_after) args.push("--snapshot-after");

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux browser navigate failed", isError: true };
    }
    return { content: stdout.trim() || `Navigated to ${url}` };
  },
};

// ---------------------------------------------------------------------------
// browser_snapshot
// ---------------------------------------------------------------------------

const browserSnapshotSchema = z.object({
  surface: z
    .string()
    .optional()
    .describe("Browser surface ref/UUID/index. Defaults to $CMUX_SURFACE_ID."),
  interactive: z
    .boolean()
    .optional()
    .describe("Include interactive elements in the snapshot"),
  compact: z
    .boolean()
    .optional()
    .describe("Compact output (fewer attributes)"),
  max_depth: z
    .number()
    .int()
    .positive()
    .optional()
    .describe("Maximum depth of the accessibility tree to include"),
  selector: z
    .string()
    .optional()
    .describe("CSS selector to restrict the snapshot to a subtree"),
});

export const browserSnapshotTool: Tool = {
  name: "cmux_browser_snapshot",
  description:
    "Capture an accessibility-tree snapshot of the current browser page. Returns a structured text representation of the visible content — use this to understand page state before clicking or typing.",
  inputSchema: browserSnapshotSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { surface, interactive, compact, max_depth, selector } =
      browserSnapshotSchema.parse(input);
    const args: string[] = ["browser", ...surfaceArg(surface), "snapshot"];
    if (interactive) args.push("--interactive");
    if (compact) args.push("--compact");
    if (max_depth !== undefined) args.push("--max-depth", String(max_depth));
    if (selector) args.push("--selector", selector);

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux browser snapshot failed", isError: true };
    }
    return { content: stdout.trim() || "(empty snapshot)" };
  },
};

// ---------------------------------------------------------------------------
// browser_click
// ---------------------------------------------------------------------------

const browserClickSchema = z.object({
  selector: z.string().describe("CSS selector of the element to click"),
  surface: z
    .string()
    .optional()
    .describe("Browser surface ref/UUID/index. Defaults to $CMUX_SURFACE_ID."),
  snapshot_after: z
    .boolean()
    .optional()
    .describe("Return an accessibility snapshot after the click"),
});

export const browserClickTool: Tool = {
  name: "cmux_browser_click",
  description:
    "Click an element in the browser by CSS selector.",
  inputSchema: browserClickSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { selector, surface, snapshot_after } = browserClickSchema.parse(input);
    const args: string[] = ["browser", ...surfaceArg(surface), "click", selector];
    if (snapshot_after) args.push("--snapshot-after");

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux browser click failed", isError: true };
    }
    return { content: stdout.trim() || `Clicked: ${selector}` };
  },
};

// ---------------------------------------------------------------------------
// browser_type
// ---------------------------------------------------------------------------

const browserTypeSchema = z.object({
  selector: z.string().describe("CSS selector of the input element"),
  text: z.string().describe("Text to type into the element"),
  surface: z
    .string()
    .optional()
    .describe("Browser surface ref/UUID/index. Defaults to $CMUX_SURFACE_ID."),
  snapshot_after: z
    .boolean()
    .optional()
    .describe("Return an accessibility snapshot after typing"),
});

export const browserTypeTool: Tool = {
  name: "cmux_browser_type",
  description:
    "Type text into a form field or editable element in the browser. Use cmux_browser_click to focus the element first if needed.",
  inputSchema: browserTypeSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { selector, text, surface, snapshot_after } = browserTypeSchema.parse(input);
    const args: string[] = ["browser", ...surfaceArg(surface), "type", selector, text];
    if (snapshot_after) args.push("--snapshot-after");

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux browser type failed", isError: true };
    }
    return { content: stdout.trim() || `Typed into ${selector}` };
  },
};

// ---------------------------------------------------------------------------
// browser_screenshot
// ---------------------------------------------------------------------------

const browserScreenshotSchema = z.object({
  out: z.string().optional().describe("File path to save the screenshot PNG"),
  surface: z
    .string()
    .optional()
    .describe("Browser surface ref/UUID/index. Defaults to $CMUX_SURFACE_ID."),
});

export const browserScreenshotTool: Tool = {
  name: "cmux_browser_screenshot",
  description:
    "Take a screenshot of the current browser page. Saves to a file if --out is given, otherwise returns path/confirmation.",
  inputSchema: browserScreenshotSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { out, surface } = browserScreenshotSchema.parse(input);
    const args: string[] = ["browser", ...surfaceArg(surface), "screenshot"];
    if (out) args.push("--out", out);

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux browser screenshot failed", isError: true };
    }
    return { content: stdout.trim() || "Screenshot taken" };
  },
};

// ---------------------------------------------------------------------------
// browser_get_url
// ---------------------------------------------------------------------------

const browserGetUrlSchema = z.object({
  surface: z
    .string()
    .optional()
    .describe("Browser surface ref/UUID/index. Defaults to $CMUX_SURFACE_ID."),
});

export const browserGetUrlTool: Tool = {
  name: "cmux_browser_get_url",
  description:
    "Return the current URL of the browser surface.",
  inputSchema: browserGetUrlSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { surface } = browserGetUrlSchema.parse(input);
    const args: string[] = ["browser", ...surfaceArg(surface), "get-url"];

    const { stdout, stderr, exitCode } = await runCmux(args);
    if (exitCode !== 0) {
      return { content: stderr || "cmux browser get-url failed", isError: true };
    }
    return { content: stdout.trim() };
  },
};

// ---------------------------------------------------------------------------
// browser_wait
// ---------------------------------------------------------------------------

const browserWaitSchema = z.object({
  surface: z
    .string()
    .optional()
    .describe("Browser surface ref/UUID/index. Defaults to $CMUX_SURFACE_ID."),
  selector: z
    .string()
    .optional()
    .describe("CSS selector to wait for (waits until element is present)"),
  text: z
    .string()
    .optional()
    .describe("Text string to wait for on the page"),
  url_contains: z
    .string()
    .optional()
    .describe("URL substring to wait for (useful after navigation/redirect)"),
  load_state: z
    .enum(["interactive", "complete"])
    .optional()
    .describe("Wait for the page to reach this load state"),
  timeout_ms: z
    .number()
    .int()
    .positive()
    .optional()
    .describe("Timeout in milliseconds (default: 30000)"),
});

export const browserWaitTool: Tool = {
  name: "cmux_browser_wait",
  description:
    "Wait for a browser condition: element present, text visible, URL match, or page load state. Blocks until the condition is met or times out.",
  inputSchema: browserWaitSchema,
  defaultPermission: "allow",

  async run(input: unknown): Promise<ToolResult> {
    const { surface, selector, text, url_contains, load_state, timeout_ms } =
      browserWaitSchema.parse(input);
    const args: string[] = ["browser", ...surfaceArg(surface), "wait"];
    if (selector) args.push("--selector", selector);
    if (text) args.push("--text", text);
    if (url_contains) args.push("--url-contains", url_contains);
    if (load_state) args.push("--load-state", load_state);
    if (timeout_ms !== undefined) args.push("--timeout-ms", String(timeout_ms));

    const timeoutMs = (timeout_ms ?? 30_000) + 5_000; // give a bit of headroom
    const { stdout, stderr, exitCode } = await runCmux(args, { timeoutMs });
    if (exitCode !== 0) {
      return { content: stderr || "cmux browser wait failed", isError: true };
    }
    return { content: stdout.trim() || "Wait condition satisfied" };
  },
};

export const browserTools: Tool[] = [
  browserNavigateTool,
  browserSnapshotTool,
  browserOpenTool,
  browserClickTool,
  browserTypeTool,
  browserGetUrlTool,
  browserScreenshotTool,
  browserWaitTool,
];
