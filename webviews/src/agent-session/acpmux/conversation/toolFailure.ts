// Why a tool call failed, in one line (Leo 2026-10-22: "we need to have prettier errors"). A failed
// call's result is the harness's raw text: Claude Code's "Exit code 1" over the shell's output, a
// hook's "PreToolUse:Bash hook error: Blocked: …", its long refusal when the person declined the
// call, a `<tool_use_error>` tag, Codex's `{"status":"declined"}`, or an MCP server's JSON error.
// The row says what happened in a word (blocked, denied, timed out, Exit 1, failed) and one quiet
// line says why, in the tool's own words without the envelope; the raw result stays in the opened
// call. Only a failed call is read: its text is cleaned whole (colour codes, a fence, a host's
// injected context; all linear, once per call), and only its first and last few thousand
// characters are searched for the cause.
import { stripAnsi } from "./toolOutput";
import { isFailed } from "./toolGroups";
import { cleanText } from "./mcpCalls";
import type { AcpmuxActivity } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// What stopped the call: a hook refused it, the person declined it, it ran out of time, its
/// command exited nonzero, or it failed some other way.
export type ToolFailureKind = "hook" | "denied" | "timeout" | "exit" | "error";

export type ToolFailure = {
  kind: ToolFailureKind;
  /// The command's exit code: the call's own (Codex), else Claude Code's "Exit code N" line.
  exitCode?: number;
  /// The hook event that refused the call ("PreToolUse"). Never drawn: the row says "blocked by hook".
  hook?: string;
  /// Why, in one line of the tool's own words; undefined when the word says it all. A hook's cause
  /// is never drawn under its row: its words are the opened call's output.
  cause?: string;
  /// The output without Claude Code's leading "Exit code N" line, which the Shell block says itself;
  /// for a hook's block, the hook's words without the harness's envelope.
  output?: string;
  /// The whole result without colour codes, a fence or injected context, its "Exit code N" line
  /// included: what Copy error copies.
  detail: string;
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
/// The person declined the call: Claude Code's refusal text or its permission denial, which is the
/// whole result of a call that never ran. Anchored, and read only from a result with no exit code,
/// so a command whose output quotes a denial ("Expected: user declined") still reads as its exit.
const DENIED =
  /^(?:the user doesn't want to proceed with this tool use|the tool use was rejected|permission to use \S+ (?:has been|was) denied|(?:the )?user (?:rejected|declined|denied|refused)\b)/i;
/// What the person told the agent when they declined (Claude Code: "… the user said:\n<words>").
const DENIED_SAID = /the user said:\s*([\s\S]+)$/i;
/// The harness's own timeout line, the result's first or last line (never one in the middle of a log).
const TIMED_OUT = /^(?:command )?timed out after \S/i;
const TOOL_USE_ERROR = /<tool_use_error>([\s\S]*?)<\/tool_use_error>/;
/// A line that names the failure, in a shell's output: the last one is the cause.
const ERROR_LINE =
  /\b(?:error|errors|fatal|failed|failure|exception|panic(?:ked)?|denied|not found|no such|cannot|can't|couldn't|could not|unable|refused|invalid|missing|timed out)\b/i;
/// An errno code that starts a line (`ENOENT: …`), in capitals only: "Expected: 3" is not one.
const ERRNO_LINE = /^E[A-Z]{3,}\b/;
/// A summary that reports none ("Found 0 errors", "0 failed") names no failure.
const NONE_LINE = /\b(?:0|no) (?:errors?|failed|failures?|warnings?)\b/i;
const namesError = (line: string) => (ERROR_LINE.test(line) || ERRNO_LINE.test(line.trim())) && !NONE_LINE.test(line);

/// A line with words in any script (`\w` is ASCII only: "访问被拒绝" has none).
const WORDS = /[\p{L}\p{N}]/u;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  Boolean(value) && typeof value === "object" && !Array.isArray(value);

/// One line: the first line of `text` that has words, as a terminal draws it, trimmed, without an
/// "Error:" lead, cut to MAX_CAUSE.
function oneLine(text: string | undefined): string | undefined {
  if (!text) return undefined;
  const line = text
    .split("\n")
    // A line a carriage return redrew (a progress bar) reads as a terminal draws it: its last part.
    .map((part) =>
      (
        part
          .split("\r")
          .filter((drawn) => WORDS.test(drawn))
          .at(-1) ?? part
      ).trim(),
    )
    .find((part) => WORDS.test(part));
  if (!line) return undefined;
  const bare = line.replace(/^(?:error|err|fatal)\s*:\s*/i, "").trim() || line;
  if (bare.length <= MAX_CAUSE) return bare;
  // A cut never splits a surrogate pair (an emoji).
  let end = MAX_CAUSE - 1;
  if (/[\uDC00-\uDFFF]/.test(bare[end] ?? "")) end--;
  return `${bare.slice(0, end)}…`;
}

/// A shell's cause: its last line that names an error, else (`fallback`) its last line with words.
function shellCause(lines: readonly string[], fallback: boolean): string | undefined {
  for (let at = lines.length - 1; at >= 0; at--) if (namesError(lines[at]!)) return oneLine(lines[at]);
  return fallback ? oneLine(lines.at(-1)) : undefined;
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

/// An error a JSON result names, through JSON inside its text (an MCP text block that is itself a
/// JSON error), without the context a host injects into it, as the opened call's response reads.
function nestedCause(value: unknown): string | undefined {
  let said = jsonCause(value);
  for (let depth = 0; depth < 3 && said !== undefined; depth++) {
    const inner = jsonCause(parseJson(cleanText(said).trim()));
    if (inner === undefined) break;
    said = inner;
  }
  return said === undefined ? undefined : cleanText(said);
}

function parseJson(text: string): unknown {
  if (text.length > MAX_JSON || !/^\s*\{/.test(text)) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/// A result's text as its opened call draws it: no fence around it and no colour codes. A call
/// that is not a shell also loses the context a host injects into it (`<system-reminder>`), as
/// ToolRow.tsx's output does.
function drawn(raw: string, shell: boolean): string {
  // A lone carriage return (a progress bar's redraw) stays, as in the Shell block of a call that worked.
  let text = stripAnsi(raw).replace(/\r\n/g, "\n");
  // Claude Code's ACP results may put a tool's text in a fence.
  const fenced = /^\s*```[\w-]*\n([\s\S]*?)\n```\s*$/.exec(text);
  if (fenced) text = fenced[1]!;
  return (shell ? text : cleanText(text)).replace(/^(?:[ \t]*\n)+/, "");
}

/// Whether a row draws `tool` as failed: by its status or a nonzero exit (toolGroups.ts isFailed),
/// as a command row reads it. A shell that went on in the background fails only by its status: its
/// exit code is how it ended there, which its background mark says.
export const rowFailed = (tool: Tool) => (tool.background ? tool.status === "failed" : isFailed(tool));

/// Why `tool` failed, or undefined when it did not.
export function toolFailure(tool: Tool): ToolFailure | undefined {
  if (!rowFailed(tool)) return undefined;
  const shell = tool.kind === "execute" && Boolean(tool.command);
  const full = drawn(tool.output ?? "", shell);
  let exitCode = tool.exitCode;
  // Claude Code's first line: the Shell block says the exit code itself, so it draws the output
  // without that line. A call with its own exit code (Codex) keeps a first line that differs.
  const header = EXIT_LINE.exec(full);
  const exit = header && (exitCode === undefined || exitCode === Number(header[1])) ? header : null;
  if (exit) exitCode ??= Number(exit[1]);
  const body = exit ? full.slice(exit[0].length) : full;
  const output = exit ? body : undefined;
  // A JSON result is read whole while small; a long result is read at its ends only, where its
  // cause is.
  const json = body.length <= MAX_JSON ? parseJson(body) : undefined;
  // The tail starts on a whole line, never half a line (or half a character).
  const tail = () => body.slice(-TAIL_CHARS).replace(/^[^\n]*\n/, "");
  const text = (body.length > HEAD_CHARS + TAIL_CHARS ? `${body.slice(0, HEAD_CHARS)}\n${tail()}` : body).trim();

  // A refusal or a hook's block is the whole result of a call that never ran, so it carries no exit
  // code; a command that ran and printed the same words ("payment declined") is read as its exit.
  const ran = exitCode !== undefined;
  if (!ran && isRecord(json) && json.status === "declined") return { kind: "denied", exitCode, output, detail: full };
  const hook = ran ? null : HOOK.exec(text);
  if (hook) {
    // Claude Code names the hook's command in brackets before its words: `[~/hooks/guard.sh]: Blocked: …`.
    const reason = text
      .slice(hook[0].length)
      .replace(/^\[[^\]\n]*\]\s*:\s*/, "")
      .replace(/^blocked\s*:\s*/i, "");
    // The row says "blocked by hook" and nothing under it; opened, the call shows the hook's words
    // as its output, without the harness's "PreToolUse:Bash hook error:" envelope (Leo,
    // 2026-10-31: "WHY IS THERE PRETOOLUSE").
    // `text` starts as the trimmed body does, so the match's length cuts the whole body too.
    const said = body
      .trimStart()
      .slice(hook[0].length)
      .replace(/^\[[^\]\n]*\]\s*:\s*/, "")
      .replace(/^blocked\s*:\s*/i, "")
      .trim();
    return {
      kind: "hook",
      hook: hook[1] ?? hook[2],
      cause: oneLine(reason),
      exitCode,
      output: said || output,
      detail: full,
    };
  }
  if (!ran && DENIED.test(text))
    return { kind: "denied", cause: oneLine(DENIED_SAID.exec(text)?.[1]), exitCode, output, detail: full };

  const lines = text.split("\n").filter((line) => WORDS.test(line));
  // "timed out" says it all; the row's time (on hover) says how long it ran.
  const timedOut = [lines[0], lines.at(-1)].some((line) => line !== undefined && TIMED_OUT.test(line.trim()));
  if (timedOut || exitCode === 124) return { kind: "timeout", exitCode, output, detail: full };

  const tagged = TOOL_USE_ERROR.exec(text)?.[1];
  const said = json === undefined ? undefined : nestedCause(json);
  const cause = tagged
    ? oneLine(tagged)
    : json !== undefined
      ? oneLine(said)
      : exitCode !== undefined
        ? // A call that exited 0 yet failed has no last line to blame: only a line that names an error.
          shellCause(lines, exitCode !== 0)
        : oneLine(text);
  if (exitCode !== undefined && exitCode !== 0) return { kind: "exit", exitCode, cause, output, detail: full };
  return { kind: "error", cause, exitCode, output, detail: full };
}

/// A shell call's output as its Shell block draws it: without colour codes (toolOutput.tsx
/// useOutput), and without Claude Code's leading "Exit code N" line, which the block says once at
/// its end. Find in Chat counts this text (chatFind.ts).
export function shellOutput(tool: Tool): string | undefined {
  const output = toolFailure(tool)?.output ?? tool.output;
  return output === undefined ? undefined : stripAnsi(output);
}

/// A call's result as its opened row draws it: a hook's block without the harness's
/// "PreToolUse:… hook error:" envelope (Find in Chat counts the same text, chatFind.ts), any other
/// call's result as it came.
/// Only a failed call that never ran (no exit code) can be a hook's block, so no other call is read.
export function callOutput(tool: Tool, failure?: ToolFailure): string | undefined {
  if (tool.status !== "failed" || tool.exitCode !== undefined) return tool.output;
  const read = failure ?? toolFailure(tool);
  return read?.kind === "hook" ? (read.output ?? tool.output) : tool.output;
}
