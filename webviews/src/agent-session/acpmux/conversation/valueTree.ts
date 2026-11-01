// A JSON value as an opened cmux script's result reads (CmuxExecDetails.tsx): a key/value tree,
// one `key: value` a line and nested values indented under their key, list items marked `- `, as
// YAML reads, never escaped JSON. Text shows as itself, its line breaks real ones and indented
// under its key; text that holds JSON is read as the value it holds; a host's injected context
// (`<system-reminder>`, mcpCalls.ts cleanText) is dropped. Keys, text and numbers take the code
// colors of their roles. Bounded: at most MAX_LINES lines and MAX_DEPTH levels, the rest one `…`.
import { losesNumbers } from "./toolResult";
import type { CodeToken } from "./jsHighlight";

export type TreeLine = CodeToken[];

const MAX_LINES = 2_000;
const MAX_DEPTH = 16;
const MORE = "…";

/** The value's lines. `clean` drops a host's injected context from text. */
export function valueTree(value: unknown, clean: (text: string) => string = (text) => text): TreeLine[] {
  const lines: TreeLine[] = [];
  let full = false;
  const add = (line: TreeLine) => {
    if (full) return;
    if (lines.length >= MAX_LINES) {
      lines.push([{ text: MORE }]);
      full = true;
      return;
    }
    lines.push(line);
  };
  const pad = (depth: number) => "  ".repeat(depth);
  const text = (raw: string): unknown => {
    if (/^\s*[[{]/.test(raw) && !losesNumbers(raw)) {
      try {
        return JSON.parse(raw);
      } catch {
        // Not JSON after all: the text as itself.
      }
    }
    return clean(raw).replace(/\n$/, "");
  };
  const scalar = (entry: unknown): CodeToken | undefined => {
    if (entry === null) return { text: "null", role: "constant" };
    if (typeof entry === "number" || typeof entry === "boolean") return { text: String(entry), role: "constant" };
    if (typeof entry === "string" && !entry.includes("\n")) return { text: entry || '""', role: "string" };
    if (Array.isArray(entry) && entry.length === 0) return { text: "[]" };
    if (isRecord(entry) && Object.keys(entry).length === 0) return { text: "{}" };
    if (entry === undefined) return { text: "undefined", role: "constant" };
    return undefined;
  };
  /// `head` is what leads the value's first line (`key: ` or `- `), at `depth`. A list item that
  /// is an object starts its first key on the item's own line (`- id: ws_1`), as YAML reads.
  const walk = (entry: unknown, depth: number, head: CodeToken[], item = false) => {
    if (full) return;
    const value = typeof entry === "string" ? text(entry) : entry;
    const one = scalar(value);
    if (one) {
      add([...head, one]);
      return;
    }
    if (depth > MAX_DEPTH) {
      add([...head, { text: MORE }]);
      return;
    }
    if (typeof value === "string") {
      // Text on several lines: each under its key, one level in.
      if (head.length) add(trimEnd(head));
      for (const line of value.split("\n"))
        add([{ text: pad(head.length ? depth + 1 : depth) }, { text: line, role: "string" }]);
      return;
    }
    if (item && isRecord(value)) {
      for (const [index, [key, child]] of Object.entries(value).entries())
        walk(child, depth + 1, [
          index === 0 ? head[0]! : { text: pad(depth + 1) },
          { text: key, role: "attribute" },
          { text: ": " },
        ]);
      return;
    }
    if (head.length) add(trimEnd(head));
    const inner = head.length ? depth + 1 : depth;
    if (Array.isArray(value)) {
      for (const child of value) walk(child, inner, [{ text: `${pad(inner)}- ` }], true);
      return;
    }
    for (const [key, child] of Object.entries(value as Record<string, unknown>))
      walk(child, inner, [{ text: pad(inner) }, { text: key, role: "attribute" }, { text: ": " }]);
  };
  walk(value, 0, []);
  return lines;
}

/// A head without its trailing space, for a key whose value goes on the lines under it (`key:`).
function trimEnd(head: CodeToken[]): CodeToken[] {
  const last = head[head.length - 1]!;
  return [...head.slice(0, -1), { ...last, text: last.text.replace(/ $/, "") }].filter((token) => token.text);
}

/** The tree's text, as it draws: its lines joined by line breaks. */
export function treeText(lines: readonly TreeLine[]): string {
  return lines.map((line) => line.map((token) => token.text).join("")).join("\n");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
