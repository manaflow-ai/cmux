/**
 * --print / headless mode. Streams assistant text to stdout, tool calls as a
 * compact one-liner to stderr, and exits when the agent emits message_stop
 * without further tool calls.
 *
 * Designed for scripting:
 *   echo "summarize the diff" | cmux101 -p
 *   cmux101 -p "explain this file"
 */

import { Runner, type RunnerEvent } from "../core/runner.ts";
import type { Provider, SessionHandle, ToolRegistry, Permissions, SubagentDispatcher, HookEvent, HookResponse } from "../core/types.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface PrintOptions {
  session: SessionHandle;
  provider: Provider;
  toolRegistry: ToolRegistry;
  permissions: Permissions;
  cwd: string;
  prompt: string;
  abortController?: AbortController;
  spawnSubagent?: SubagentDispatcher;
  emitHook?: (event: HookEvent) => Promise<HookResponse>;
  verbose?: boolean;
  jsonStream?: boolean;
  /** Suppress all tool output; only final assistant text is shown. */
  quiet?: boolean;
  /** Output format: "text" (default) or "json" (NDJSON). */
  outputFormat?: "text" | "json";
  /** Called with the Runner instance just before run(), so callers can access getUsage(). */
  onRunnerCreated?: (runner: Runner) => void;
}

export interface PrintFormatOpts {
  verbose?: boolean;
  quiet?: boolean;
  outputFormat?: "text" | "json";
  /** Whether the output terminal supports color (default: false for stderr). */
  isTTY?: boolean;
}

// ---------------------------------------------------------------------------
// Tool names that get "first 20 lines" treatment
// ---------------------------------------------------------------------------

const MULTILINE_TOOLS = new Set([
  "cmux_tree",
  "cmux_read_screen",
  "file_read",
  "grep",
  "glob",
]);

const SHELL_TOOLS = new Set(["shell", "bash", "run_command"]);
const FILE_EDIT_TOOLS = new Set(["file_edit", "str_replace_editor"]);

// ---------------------------------------------------------------------------
// Pure formatting helpers
// ---------------------------------------------------------------------------

function truncate(s: string, n: number): string {
  if (s.length <= n) return s;
  return s.slice(0, n) + "…";
}

function firstNLines(s: string, n: number): string {
  const lines = s.split("\n");
  if (lines.length <= n) return s;
  return lines.slice(0, n).join("\n") + `\n…(${lines.length - n} more lines)`;
}

function extractContent(result: unknown): string {
  if (typeof result === "string") return result;
  if (result && typeof result === "object") {
    const r = result as Record<string, unknown>;
    if (typeof r["content"] === "string") return r["content"];
    if (Array.isArray(r["content"])) {
      return r["content"]
        .filter((b: unknown) => b && typeof b === "object" && (b as Record<string, unknown>)["type"] === "text")
        .map((b: unknown) => (b as Record<string, unknown>)["text"] as string)
        .join("");
    }
  }
  return String(result ?? "");
}

function colorDiff(diffText: string, isTTY: boolean): string {
  if (!isTTY) return diffText;
  return diffText
    .split("\n")
    .map((line) => {
      if (line.startsWith("+") && !line.startsWith("+++")) return `\x1b[32m${line}\x1b[0m`;
      if (line.startsWith("-") && !line.startsWith("---")) return `\x1b[31m${line}\x1b[0m`;
      return line;
    })
    .join("\n");
}

function formatDiff(content: string, isTTY: boolean): string {
  const isDiff = content.trimStart().startsWith("Index:") || content.trimStart().startsWith("--- ");
  if (!isDiff) return truncate(content, 300);
  return colorDiff(content, isTTY);
}

function formatShellResult(content: string): string {
  const lines = content.split("\n");
  // Try to find exit code line (often last non-empty line or "Exit code: N")
  const exitLine = lines.find((l) => /^exit\s*(code)?[:\s]/i.test(l.trim()));
  const outputLines = lines.filter((l) => !/^exit\s*(code)?[:\s]/i.test(l.trim()));
  const truncated = firstNLines(outputLines.join("\n"), 20);
  return exitLine ? `${exitLine}\n${truncated}` : truncated;
}

function formatToolResult(toolName: string, result: unknown, isError: boolean, opts: { verbose?: boolean; isTTY?: boolean }): string {
  const content = extractContent(result);
  if (isError) return content;
  if (opts.verbose) return content;

  if (FILE_EDIT_TOOLS.has(toolName)) {
    return formatDiff(content, opts.isTTY ?? false);
  }
  if (SHELL_TOOLS.has(toolName)) {
    return formatShellResult(content);
  }
  if (MULTILINE_TOOLS.has(toolName)) {
    return firstNLines(content, 20);
  }
  return truncate(content, 300);
}

// ---------------------------------------------------------------------------
// Pure event formatter
// ---------------------------------------------------------------------------

export interface FormattedOutput {
  /** Lines/fragments to write to stderr (for tool events, thinking, errors). */
  stderr?: string;
  /** Lines/fragments to write to stdout (for text delta, turn_end, JSON). */
  stdout?: string;
}

/**
 * Pure function: converts a single RunnerEvent into output strings.
 * No I/O is performed here — the caller decides where to write.
 *
 * State must be passed in / updated externally when needed (e.g. tool name cache).
 */
export function formatEvent(
  event: RunnerEvent,
  opts: PrintFormatOpts,
  /** Mutable state bag shared across calls for a single session. */
  state: { toolNames: Map<string, string> },
): FormattedOutput {
  const isTTY = opts.isTTY ?? false;
  const quiet = opts.quiet ?? false;
  const verbose = opts.verbose ?? false;
  const jsonMode = (opts.outputFormat ?? "text") === "json";

  // JSON / NDJSON mode
  if (jsonMode) {
    switch (event.kind) {
      case "stream": {
        const se = event.event;
        if (se.kind === "text_delta") {
          return { stdout: JSON.stringify({ kind: "text_delta", text: se.text }) + "\n" };
        }
        return {};
      }
      case "tool_pre":
        state.toolNames.set(event.toolUseId, event.name);
        return {
          stdout: JSON.stringify({ kind: "tool_call", name: event.name, input: event.input ?? {}, id: event.toolUseId }) + "\n",
        };
      case "tool_post": {
        const content = extractContent(event.result);
        return {
          stdout: JSON.stringify({ kind: "tool_result", id: event.toolUseId, content, isError: event.isError }) + "\n",
        };
      }
      case "turn_end": {
        // usage may not be in event; emit what we can
        const payload: Record<string, unknown> = { kind: "turn_end", reason: event.reason };
        return { stdout: JSON.stringify(payload) + "\n" };
      }
      case "error":
        return { stdout: JSON.stringify({ kind: "error", message: event.error.message }) + "\n" };
      default:
        return {};
    }
  }

  // Text mode
  switch (event.kind) {
    case "stream": {
      const se = event.event;
      if (se.kind === "text_delta") {
        return { stdout: se.text };
      }
      if (se.kind === "thinking_delta" && verbose) {
        return { stderr: `\x1b[90m${se.text}\x1b[0m` };
      }
      if (se.kind === "error") {
        return { stderr: `\n[provider error] ${se.error.message}\n` };
      }
      return {};
    }

    case "tool_pre": {
      state.toolNames.set(event.toolUseId, event.name);
      if (quiet) return {};
      return { stderr: `\n[tool] ${event.name} ${truncate(JSON.stringify(event.input ?? {}), 200)}\n` };
    }

    case "tool_output_delta": {
      if (quiet) return {};
      if (verbose) return { stderr: event.text };
      return {};
    }

    case "tool_post": {
      if (quiet) return {};
      const toolName = state.toolNames.get(event.toolUseId) ?? "unknown";
      const statusLine = event.isError ? `[tool ✗] error\n` : `[tool ✓]\n`;
      const resultText = formatToolResult(toolName, event.result, event.isError, { verbose, isTTY });
      const resultLine = resultText ? `[result] ${resultText}\n` : "";
      return { stderr: statusLine + resultLine };
    }

    case "turn_end":
      return { stdout: "\n" };

    case "error":
      return { stderr: `\n[error] ${event.error.message}\n` };

    default:
      return {};
  }
}

// ---------------------------------------------------------------------------
// I/O driver
// ---------------------------------------------------------------------------

export async function runPrint(opts: PrintOptions): Promise<void> {
  const abortController = opts.abortController ?? new AbortController();
  process.on("SIGINT", () => abortController.abort());

  const formatOpts: PrintFormatOpts = {
    verbose: opts.verbose,
    quiet: opts.quiet,
    outputFormat: opts.outputFormat ?? (opts.jsonStream ? "json" : "text"),
    isTTY: process.stderr.isTTY,
  };

  const state: { toolNames: Map<string, string> } = { toolNames: new Map() };

  const onEvent = (event: RunnerEvent) => {
    const out = formatEvent(event, formatOpts, state);
    if (out.stderr) process.stderr.write(out.stderr);
    if (out.stdout) process.stdout.write(out.stdout);
  };

  const runner = new Runner({
    session: opts.session,
    provider: opts.provider,
    toolRegistry: opts.toolRegistry,
    permissions: opts.permissions,
    abortController,
    cwd: opts.cwd,
    spawnSubagent: opts.spawnSubagent,
    emitHook: opts.emitHook,
    onEvent,
  });

  opts.onRunnerCreated?.(runner);
  await runner.run(opts.prompt);
}
