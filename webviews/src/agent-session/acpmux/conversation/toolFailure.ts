// Why a tool call failed, in one line (Leo 2026-10-22: "we need to have prettier errors"). A failed
// call's result is the harness's raw text: Claude Code's "Exit code 1" over the shell's output, a
// hook's "PreToolUse:Bash hook error: Blocked: …", its long refusal when the person declined the
// call, a `<tool_use_error>` tag, Codex's `{"status":"declined"}`, or an MCP server's JSON error.
// The row says what happened in a word (blocked, denied, timed out, Exit 1, failed) and one quiet
// line says why, in the tool's own words without the envelope; the raw result stays in the opened
// call. Only a failed call is read, and only its first and last few thousand characters.
import { stripAnsi } from "./toolOutput";
import { isFailed } from "./toolGroups";
import type { AcpmuxActivity } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// What stopped the call: a hook refused it, the person declined it, it ran out of time, its
/// command exited nonzero, or it failed some other way.
export type ToolFailureKind = "hook" | "denied" | "timeout" | "exit" | "error";

export type ToolFailure = {
  kind: ToolFailureKind;
  /// The command's exit code: the call's own (Codex), else Claude Code's "Exit code N" line.
  exitCode?: number;
  /// The hook event that refused the call ("PreToolUse").
  hook?: string;
  /// Why, in one line of the tool's own words; undefined when the word says it all.
  cause?: string;
  /// The output without Claude Code's leading "Exit code N" line, which the Shell block says itself.
  output?: string;
};

/// The most of a result read from each end: a cause sits in its first or last lines.
const HEAD_CHARS = 4_000;
const TAIL_CHARS = 4_000;
/// A cause longer than this is cut; the row ellipsizes it to one line anyway.
const MAX_CAUSE = 300;
/// A JSON result longer than this is not parsed.
const MAX_JSON = 64_000;

const EXIT_LINE = /^Exit code (-?\d+)[ \t]*(?:\r?\n|$)/;
/// Claude Code: `PreToolUse:Bash hook error: <reason>`; also `Hook PreToolUse:Bash denied …: <reason>`.
const HOOK = /^(?:(\w+)(?::[\w.-]+)? hook error|hook (\w+)(?::[\w.-]+)? (?:denied|blocked)[^:\n]*)\s*:\s*/i;
/// The person declined the call: Claude Code's refusal text, its permission denial, Codex's words.
const DENIED =
  /the user doesn't want to proceed with this tool use|the tool use was rejected|permission to use \S+ (?:has been|was) denied|(?:rejected|declined|denied) by (?:the )?user|user (?:rejected|declined|denied)/i;
/// What the person told the agent when they declined (Claude Code: "… the user said:\n<words>").
const DENIED_SAID = /the user said:\s*([\s\S]+)$/i;
const TIMED_OUT = /^(?:command )?timed out after .+$/im;
const TOOL_USE_ERROR = /<tool_use_error>([\s\S]*?)<\/tool_use_error>/;
/// A line that names the failure, in a shell's output: the last one is the cause.
const ERROR_LINE =
  /\b(?:error|errors|fatal|failed|failure|exception|panic(?:ked)?|denied|not found|no such|cannot|can't|couldn't|could not|unable|refused|invalid|missing|timed out)\b|^E[A-Z]{3,}\b/i;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  Boolean(value) && typeof value === "object" && !Array.isArray(value);

/// One line: the first line of `text` that has words, trimmed, without an "Error:" lead, cut to MAX_CAUSE.
function oneLine(text: string | undefined): string | undefined {
  if (!text) return undefined;
  const line = text
    .split("\n")
    .map((part) => part.trim())
    .find((part) => /\w/.test(part));
  if (!line) return undefined;
  const bare = line.replace(/^(?:error|err|fatal)\s*:\s*/i, "").trim() || line;
  return bare.length > MAX_CAUSE ? `${bare.slice(0, MAX_CAUSE - 1)}…` : bare;
}

/// A shell's cause: its last line that names an error, else its last line with words.
function shellCause(text: string): string | undefined {
  const lines = text.split("\n").filter((line) => /\w/.test(line));
  for (let at = lines.length - 1; at >= 0; at--) if (ERROR_LINE.test(lines[at]!)) return oneLine(lines[at]);
  return oneLine(lines.at(-1));
}

/// An error a JSON result names: `{"error":"…"}`, `{"error":{"message":"…","code":"…"}}`, an MCP
/// result with `isError` and a text block, or `{"message":"…"}`.
function jsonCause(value: unknown, depth = 0): string | undefined {
  if (!isRecord(value) || depth > 3) return undefined;
  const { error, message, content } = value;
  if (typeof error === "string" && error.trim()) return error;
  if (isRecord(error)) return jsonCause(error, depth + 1);
  if (typeof message === "string" && message.trim()) {
    const code = typeof value.code === "string" && !message.includes(value.code) ? value.code : undefined;
    return code ? `${message} (${code})` : message;
  }
  if (Array.isArray(content))
    for (const block of content) if (isRecord(block) && typeof block.text === "string") return block.text;
  return undefined;
}

function parseJson(text: string): unknown {
  if (text.length > MAX_JSON || !/^\s*\{/.test(text)) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/// Why `tool` failed, or undefined when it did not.
export function toolFailure(tool: Tool): ToolFailure | undefined {
  if (!isFailed(tool)) return undefined;
  const raw = tool.output ?? "";
  // A long result is read at its ends only; the cause is in one of them.
  const clipped = raw.length > HEAD_CHARS + TAIL_CHARS ? `${raw.slice(0, HEAD_CHARS)}\n${raw.slice(-TAIL_CHARS)}` : raw;
  let text = stripAnsi(clipped).replace(/\r\n?/g, "\n").trim();
  // Claude Code's ACP results put a tool's text in a fence.
  const fenced = /^```\w*\n([\s\S]*?)\n```$/.exec(text);
  if (fenced) text = fenced[1]!.trim();

  let exitCode = tool.exitCode;
  let output: string | undefined;
  const exit = EXIT_LINE.exec(text);
  if (exit) {
    exitCode ??= Number(exit[1]);
    text = text.slice(exit[0].length).trim();
    // The Shell block says the exit code itself; it draws the output without that line.
    const whole = EXIT_LINE.exec(raw.replace(/^\s+/, ""));
    if (whole) output = raw.replace(/^\s+/, "").slice(whole[0].length);
  }

  const json = parseJson(text);
  if (isRecord(json) && json.status === "declined") return { kind: "denied", exitCode, output };

  const hook = HOOK.exec(text);
  if (hook) {
    const reason = text.slice(hook[0].length).replace(/^blocked\s*:\s*/i, "");
    return { kind: "hook", hook: hook[1] ?? hook[2], cause: oneLine(reason), exitCode, output };
  }
  if (DENIED.test(text)) return { kind: "denied", cause: oneLine(DENIED_SAID.exec(text)?.[1]), exitCode, output };

  // "timed out" says it all; the row's time (on hover) says how long it ran.
  if (TIMED_OUT.test(text) || exitCode === 124) return { kind: "timeout", exitCode, output };

  const tagged = TOOL_USE_ERROR.exec(text)?.[1];
  const cause = tagged
    ? oneLine(tagged)
    : json !== undefined
      ? oneLine(jsonCause(json))
      : exitCode !== undefined
        ? shellCause(text)
        : oneLine(text);
  if (exitCode !== undefined && exitCode !== 0) return { kind: "exit", exitCode, cause, output };
  return { kind: "error", cause, exitCode, output };
}
