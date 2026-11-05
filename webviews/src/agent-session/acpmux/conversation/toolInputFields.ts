// A tool call's input as the opened call draws it (ToolDetail.tsx): one labeled field per argument,
// each value as the text it draws, so Find (chatFind.ts) reads what the fields show.
import { cleanText, prettyValue } from "./mcpCalls";
import { losesNumbers } from "./toolResult";

/// One argument of a call: its key, and its value as text (a string as it came, any other value
/// as the indented JSON prettyValue prints) with how to draw it.
export type InputField = { key: string; text: string; look: "prose" | "markdown" | "tree" | "value" };

/// Lines that only Markdown draws differently from plain prose: a heading, a list, a fence, a
/// quote, a table or a link, in a value of several lines.
const MARKDOWN = /^(#{1,6} |[-*+] |\d+[.)] |```|> |\|.*\|)|\[[^\]\n]+\]\([^)\s]+\)/m;

/// Marks Markdown draws on one line: bold, inline code or a link.
const INLINE_MARKDOWN = /\*\*[^*\n]+\*\*|`[^`\n]+`|\[[^\]\n]+\]\([^)\s]+\)/;

/// Calls that change files: an edit keeps its diff or its output body, never input fields, even
/// when it carries no diff (a failed or diff-less edit).
const FILE_KINDS = new Set(["edit", "delete", "move", "fileChange"]);

/// Whether a non-MCP call opens to input fields over its output (ToolRow.tsx), which Find reads the
/// same way (chatFind.ts): not a shell, not a file change, not a hook's refusal, with output to show.
export function opensToFields(
  tool: { kind?: string; command?: string; diffs?: readonly unknown[] },
  failure: { kind: string } | undefined,
): boolean {
  if (tool.kind === "execute" && tool.command) return false;
  if (tool.diffs?.length || FILE_KINDS.has(tool.kind ?? "")) return false;
  return failure?.kind !== "hook";
}

/// The fields of a call's input, in the order the harness sent them, or nil when the input is not
/// an object with at least one argument (the caller then shows it as it came).
export function inputFields(args: unknown, source?: string): InputField[] | undefined {
  const input = typeof args === "string" ? parseObject(args) : args;
  if (!isRecord(input)) return undefined;
  // A value holding a number a double would change (a 64-bit ID) shows as the agent spelled it,
  // never parsed and rounded (toolResult.ts losesNumbers).
  const raw = source ?? (typeof args === "string" ? args : undefined);
  const exact = raw && losesNumbers(raw) ? rawMembers(raw) : undefined;
  const fields: InputField[] = [];
  for (const [key, value] of Object.entries(input)) {
    if (value === undefined) continue;
    const spelled = exact?.get(key);
    if (spelled !== undefined && losesNumbers(spelled)) {
      fields.push({ key, text: spelled, look: typeof value === "object" ? "tree" : "value" });
      continue;
    }
    // An empty argument is still one the agent passed: it shows as the JSON it is, so the opened
    // call names every argument (generic calls have no Raw to fall back on).
    if (value === null || value === "" || (typeof value === "object" && Object.keys(value).length === 0)) {
      fields.push({ key, text: JSON.stringify(value), look: "value" });
    } else if (typeof value === "string") {
      // Without the context a host injects into it (`<system-reminder>`), as the request reads.
      const text = cleanText(value).replace(/\n$/, "");
      if (!text.trim()) continue;
      fields.push({
        key,
        text,
        look: (text.includes("\n") && MARKDOWN.test(text)) || INLINE_MARKDOWN.test(text) ? "markdown" : "prose",
      });
    } else if (Array.isArray(value) && value.length > 0 && value.every(isScalar) && value.join(", ").length <= 120) {
      // A short list of words or numbers reads as one line ("bug, frontend"), not a bracketed tree.
      fields.push({
        key,
        text: value.map((entry) => (typeof entry === "string" ? cleanText(entry) : entry)).join(", "),
        look: "prose",
      });
    } else if (typeof value === "object") {
      const text = prettyValue(value);
      if (text) fields.push({ key, text, look: "tree" });
    } else {
      fields.push({ key, text: String(value), look: "value" });
    }
  }
  return fields.length ? fields : undefined;
}

/// The raw JSON text of a call's arguments: the whole input, or a Codex MCP envelope's `arguments`
/// (mcpCalls.ts mcpCall), so a caller can show them as spelled.
export function argsSource(tool: { title: string; inputSummary?: string }): string | undefined {
  const input = tool.inputSummary;
  if (!input || tool.title.trim().startsWith("mcp__")) return input;
  return rawMembers(input)?.get("arguments") ?? input;
}

/// The request as the MCP Raw view and Find show it: pretty, or as it came when parsing it would
/// round a number.
export function requestText(args: unknown, source: string | undefined): string | undefined {
  if (source && losesNumbers(source) && parseObject(source) !== undefined) return source.trim();
  return prettyValue(args);
}

/// Each top-level member of a JSON object's text, as it is spelled there, by key; undefined when
/// the text is not one object.
export function rawMembers(text: string): Map<string, string> | undefined {
  const source = text.trim();
  if (!source.startsWith("{") || parseObject(source) === undefined) return undefined;
  const members = new Map<string, string>();
  let depth = 0;
  let start = 1;
  let inString = false;
  const take = (end: number) => {
    const member = source.slice(start, end);
    const colon = keyEnd(member);
    if (colon > 0) members.set(JSON.parse(member.slice(0, colon).trim()) as string, member.slice(colon + 1).trim());
  };
  for (let index = 1; index < source.length; index++) {
    const char = source[index];
    if (inString) {
      if (char === "\\") index++;
      else if (char === '"') inString = false;
    } else if (char === '"') inString = true;
    else if (char === "{" || char === "[") depth++;
    else if ((char === "}" || char === "]") && depth > 0) depth--;
    else if (depth === 0 && (char === "," || char === "}")) {
      take(index);
      start = index + 1;
    }
  }
  return members;
}

/// The index of the colon after a member's key string.
function keyEnd(member: string): number {
  for (let index = member.indexOf('"') + 1; index > 0 && index < member.length; index++) {
    if (member[index] === "\\") index++;
    else if (member[index] === '"') return member.indexOf(":", index);
  }
  return -1;
}

function parseObject(text: string): unknown {
  const trimmed = text.trim();
  if (!trimmed.startsWith("{")) return undefined;
  try {
    return JSON.parse(trimmed);
  } catch {
    return undefined;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/// What Find reads of the fields: each value as it draws (a Markdown value as its words, by
/// `plain`); the keys are labels it skips.
export function fieldsText(fields: readonly InputField[], plain: (markdown: string) => string): string {
  return fields.map((field) => (field.look === "markdown" ? plain(field.text) : field.text)).join("\n");
}

function isScalar(value: unknown): value is string | number | boolean {
  return (
    (typeof value === "string" && !value.includes("\n")) || typeof value === "number" || typeof value === "boolean"
  );
}
