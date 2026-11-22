import type { EventRecord } from "./direct";
import { type Translate, translate } from "./i18n";
import { type WireEntry } from "./wire";

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
};

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
  return {
    key: `w${entry.seq}`,
    at: entry.at,
    dir: entry.dir,
    kind: entry.kind,
    name,
    latencyMs: entry.latencyMs,
    size: entry.size,
    body,
  };
}

export function sessionRow(event: EventRecord, t: Translate = translate): InspectorRow {
  const method = typeof event.msg?.method === "string" ? event.msg.method : undefined;
  const update = event.msg?.params?.update?.sessionUpdate;
  const name = [method, typeof update === "string" ? update : undefined].filter(Boolean).join(" ") || event.kind;
  return {
    key: `s${event.seq}`,
    at: event.at,
    dir: event.dir,
    kind: event.kind,
    name: t("inspector.sequence", { name, seq: event.seq }),
    body: JSON.stringify(event.msg, null, 2),
  };
}

/** The newest `SHOWN_ROWS` rows whose name, kind or body contains `filter` (case-insensitive). */
export function visibleRows(rows: InspectorRow[], filter: string): InspectorRow[] {
  const needle = filter.trim().toLowerCase();
  const matching = needle
    ? rows.filter(
        (row) =>
          row.name.toLowerCase().includes(needle) ||
          row.kind.includes(needle) ||
          row.body.toLowerCase().includes(needle),
      )
    : rows;
  return matching.slice(-SHOWN_ROWS);
}
