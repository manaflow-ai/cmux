import type { EventRecord } from "./direct";
import { type Translate, translate } from "./i18n";
import { type WireEntry } from "./wire";
import { UI_PICK_HEADER } from "./composer/uiPickModel";

/** Rows rendered per view; the newest are kept. */
export const SHOWN_ROWS = 500;

/** `acp-<session8>-<yyyyMMdd-HHmmss>.jsonl` in local time; `acp-<time>.jsonl` without a session. */
export function exportFileName(sessionId: string | undefined, at: Date): string {
  const pad = (value: number) => String(value).padStart(2, "0");
  const stamp = `${at.getFullYear()}${pad(at.getMonth() + 1)}${pad(at.getDate())}-${pad(at.getHours())}${pad(at.getMinutes())}${pad(at.getSeconds())}`;
  return ["acp", sessionId?.slice(0, 8), stamp].filter(Boolean).join("-") + ".jsonl";
}

export type InspectorRow = {
  key: string;
  at: number;
  dir: string;
  kind: string;
  name: string;
  latencyMs?: number;
  size?: number;
  body: string;
  /** The elements this message points at (Point at Element picks it carries), in order; unset when none. */
  pointed?: string[];
};

/// The first line of a native element's report (the native half of Point at Element: tabs, panes and
/// sidebar rows, UIPointerNativeElement.report). Its second line is `<kind>: <title>`.
export const NATIVE_PICK_HEADER = "cmux native UI element";

/// How far past a report's first line its element line is looked for, in characters.
const PICK_LINE_WINDOW = 400;

/// JSON string escapes back to their characters, for a report read out of a message's raw JSON text.
function unescapeJson(text: string): string {
  return text.replace(/\\(u[0-9a-fA-F]{4}|["\\/bfnrt])/g, (_, code: string) => {
    if (code.startsWith("u")) return String.fromCharCode(parseInt(code.slice(1), 16));
    return ({ b: "\b", f: "\f", n: "\n", r: "\r", t: "\t" } as Record<string, string>)[code] ?? code;
  });
}

/// The element a report names, from the lines after its first: a webview pick's `Component:`, a
/// native pick's `<kind>: <title>` (as `<kind> "<title>"`).
function pickedName(header: string, rest: string): string | undefined {
  const lines = unescapeJson(rest).split(/\r\n|\n|\r/);
  if (header === UI_PICK_HEADER) {
    const component = lines
      .slice(1, 4)
      .map((line) => /^Component: ?(.*)$/.exec(line)?.[1]?.trim())
      .find(Boolean);
    return component && component !== "unavailable" ? component : undefined;
  }
  const match = /^([^:]+): (.+)$/.exec(lines[1]?.trim() ?? "");
  return match ? `${match[1]} "${match[2]}"` : undefined;
}

/// The elements a message points at: each Point at Element report in it (UI_PICK_HEADER for a
/// webview pick, NATIVE_PICK_HEADER for a native one), by the element it names, in order and without
/// repeats. Reads plain text or a message's raw JSON text (where the report's newlines are `\n`).
export function pointedElements(text: string | undefined): string[] {
  if (!text || (!text.includes(UI_PICK_HEADER) && !text.includes(NATIVE_PICK_HEADER))) return [];
  const found: { at: number; name: string }[] = [];
  for (const header of [UI_PICK_HEADER, NATIVE_PICK_HEADER]) {
    for (let at = text.indexOf(header); at >= 0; at = text.indexOf(header, at + header.length)) {
      const name = pickedName(header, text.slice(at, at + header.length + PICK_LINE_WINDOW));
      if (name) found.push({ at, name });
    }
  }
  return [...new Set(found.sort((a, b) => a.at - b.at).map((pick) => pick.name))];
}

function withPointed(row: InspectorRow, text: string | undefined): InspectorRow {
  const pointed = pointedElements(text);
  return pointed.length ? { ...row, pointed } : row;
}

/** HH:MM:SS.mmm in local time. */
export function clockTime(at: number): string {
  const date = new Date(at);
  const pad = (value: number, width = 2) => String(value).padStart(width, "0");
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}.${pad(date.getMilliseconds(), 3)}`;
}

function pretty(text: string | undefined, fallback: unknown): string {
  if (text !== undefined) {
    try {
      return JSON.stringify(JSON.parse(text), null, 2);
    } catch {
      return text;
    }
  }
  return fallback === undefined ? "" : JSON.stringify(fallback, null, 2);
}

export function wireRow(entry: WireEntry, t: Translate = translate): InspectorRow {
  const name =
    entry.kind === "lifecycle"
      ? (entry.event ?? "")
      : [entry.method, entry.id !== undefined ? `#${entry.id}` : undefined].filter(Boolean).join(" ");
  const body =
    pretty(entry.text, entry.detail) +
    (entry.truncated
      ? `\n${t("inspector.truncated", { shown: entry.text?.length ?? 0, total: entry.size ?? 0 })}`
      : "");
  return withPointed(
    {
      key: `w${entry.seq}`,
      at: entry.at,
      dir: entry.dir,
      kind: entry.kind,
      name,
      latencyMs: entry.latencyMs,
      size: entry.size,
      body,
    },
    entry.text,
  );
}

export function sessionRow(event: EventRecord, t: Translate = translate): InspectorRow {
  const method = typeof event.msg?.method === "string" ? event.msg.method : undefined;
  const update = event.msg?.params?.update?.sessionUpdate;
  const name = [method, typeof update === "string" ? update : undefined].filter(Boolean).join(" ") || event.kind;
  const body = JSON.stringify(event.msg, null, 2);
  return withPointed(
    {
      key: `s${event.seq}`,
      at: event.at,
      dir: event.dir,
      kind: event.kind,
      name: t("inspector.sequence", { name, seq: event.seq }),
      body,
    },
    body,
  );
}

/** The newest `SHOWN_ROWS` rows whose name, kind or body contains `filter` (case-insensitive);
 * with `pointedOnly`, only the rows that point at an element. */
export function visibleRows(rows: InspectorRow[], filter: string, pointedOnly = false): InspectorRow[] {
  const needle = filter.trim().toLowerCase();
  const pointing = pointedOnly ? rows.filter((row) => row.pointed) : rows;
  const matching = needle
    ? pointing.filter(
        (row) =>
          row.name.toLowerCase().includes(needle) ||
          row.kind.includes(needle) ||
          row.body.toLowerCase().includes(needle) ||
          row.pointed?.some((element) => element.toLowerCase().includes(needle)),
      )
    : pointing;
  return matching.slice(-SHOWN_ROWS);
}
