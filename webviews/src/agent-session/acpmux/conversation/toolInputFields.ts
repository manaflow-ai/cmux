// A tool call's input as the opened call draws it (ToolDetail.tsx): one labeled field per argument,
// each value as the text it draws, so Find (chatFind.ts) reads what the fields show.
import { prettyValue } from "./mcpCalls";

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
export function inputFields(args: unknown): InputField[] | undefined {
  const input = typeof args === "string" ? parseObject(args) : args;
  if (!isRecord(input)) return undefined;
  const fields: InputField[] = [];
  for (const [key, value] of Object.entries(input)) {
    if (value === undefined) continue;
    // An empty argument is still one the agent passed: it shows as the JSON it is, so the opened
    // call names every argument (generic calls have no Raw to fall back on).
    if (value === null || value === "" || (typeof value === "object" && Object.keys(value).length === 0)) {
      fields.push({ key, text: JSON.stringify(value), look: "value" });
    } else if (typeof value === "string") {
      const text = value.replace(/\n$/, "");
      fields.push({
        key,
        text,
        look: (text.includes("\n") && MARKDOWN.test(text)) || INLINE_MARKDOWN.test(text) ? "markdown" : "prose",
      });
    } else if (Array.isArray(value) && value.length > 0 && value.every(isScalar) && value.join(", ").length <= 120) {
      // A short list of words or numbers reads as one line ("bug, frontend"), not a bracketed tree.
      fields.push({ key, text: value.join(", "), look: "prose" });
    } else if (typeof value === "object") {
      const text = prettyValue(value);
      if (text) fields.push({ key, text, look: "tree" });
    } else {
      fields.push({ key, text: String(value), look: "value" });
    }
  }
  return fields.length ? fields : undefined;
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
