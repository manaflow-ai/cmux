// A tool call's input as the opened call draws it (ToolDetail.tsx): one labeled field per argument,
// each value as the text it draws, so Find (chatFind.ts) reads what the fields show.
import { prettyValue } from "./mcpCalls";

/// One argument of a call: its key, and its value as text (a string as it came, any other value
/// as the indented JSON prettyValue prints) with how to draw it.
export type InputField = { key: string; text: string; look: "prose" | "markdown" | "tree" | "value" };

/// Lines that only Markdown draws differently from plain prose: a heading, a list, a fence, a
/// quote, a table or a link.
const MARKDOWN = /^(#{1,6} |[-*+] |\d+[.)] |```|> |\|.*\|)|\[[^\]\n]+\]\([^)\s]+\)/m;

/// The fields of a call's input, in the order the harness sent them, or nil when the input is not
/// an object with at least one field worth showing (the caller then shows it as it came).
export function inputFields(args: unknown): InputField[] | undefined {
  const input = typeof args === "string" ? parseObject(args) : args;
  if (!isRecord(input)) return undefined;
  const fields: InputField[] = [];
  for (const [key, value] of Object.entries(input)) {
    if (value === undefined || value === null || value === "") continue;
    if (typeof value === "string") {
      const text = value.replace(/\n$/, "");
      fields.push({ key, text, look: text.includes("\n") && MARKDOWN.test(text) ? "markdown" : "prose" });
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
