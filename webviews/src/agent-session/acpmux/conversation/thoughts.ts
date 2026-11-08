// What a finished thought draws (Leo 2026-10-20, as Claude Desktop and Codex do): consecutive
// thoughts in one step are one row, and a thought with nothing to read draws no row at all.
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { PrefixFlatCache, type PrefixFlat } from "./prefixFlatMap";

/// A thought shorter than this many characters (trimmed)...
export const QUIET_THOUGHT_CHARS = 40;
/// ...that took under this long, or is undated, draws no row once done: a "Thought" over one
/// short line says nothing the reply does not.
export const QUIET_THOUGHT_MS = 1000;

/// An agent thought (not a tool call's item).
export const isThought = (item: AcpmuxActivity) => item.kind === "thought" && !item.tool;

/// How long the agent thought, from the thought's first chunk to its latest (direct.ts
/// appendThought), never negative: events out of order can date the latest before the first.
export function thoughtDuration(item: AcpmuxActivity): number | undefined {
  if (item.startedAt === undefined || item.endedAt === undefined) return undefined;
  return Math.max(0, item.endedAt - item.startedAt);
}

/// A thought that draws no row once done: empty or only whitespace (Claude's `display: "omitted"`
/// and redacted thinking reach the pane with no text, if at all), or under QUIET_THOUGHT_CHARS that
/// took under QUIET_THOUGHT_MS or is undated.
export function isQuietThought(item: AcpmuxActivity): boolean {
  const text = item.text.trim();
  if (!text) return true;
  if (text.length >= QUIET_THOUGHT_CHARS) return false;
  const ms = thoughtDuration(item);
  return ms === undefined || ms < QUIET_THOUGHT_MS;
}

/// Consecutive thoughts as one: their texts a blank line apart, dated from the first's start for
/// the sum of their durations (the time between them, such as a call a permission ask holds out of
/// the transcript, is not thinking). `items` itself when no two thoughts touch.
export function mergeThoughts(items: readonly AcpmuxActivity[]): readonly AcpmuxActivity[] {
  if (!items.some((item, index) => index > 0 && isThought(item) && isThought(items[index - 1]!))) return items;
  const out: AcpmuxActivity[] = [];
  for (const item of items) {
    const last = out.at(-1);
    if (!last || !isThought(item) || !isThought(last)) {
      out.push(item);
      continue;
    }
    const text = [last.text.trim(), item.text.trim()].filter(Boolean).join("\n\n");
    const before = thoughtDuration(last);
    const after = thoughtDuration(item);
    const ms = before === undefined && after === undefined ? undefined : (before ?? 0) + (after ?? 0);
    const startedAt = last.startedAt ?? item.startedAt;
    out[out.length - 1] = {
      ...last,
      text,
      ...(ms !== undefined && startedAt !== undefined && { startedAt, endedAt: startedAt + ms }),
    };
  }
  return out;
}

/// Each row as drawn: its thoughts merged and quiet ones left out (WeakMap: one result per row
/// object, so an unchanged row keeps its identity for turnViewFrom and the row memo).
const shaped = new WeakMap<AcpmuxRow, AcpmuxRow | null>();

/// A changed row takes a fractional version no row reaches by itself, one for each `keepLast`, so
/// the transcript draws it again when its turn stops working (permissions/askRows.ts adds 0.5).
function shapeRow(row: AcpmuxRow, keepLast: boolean): AcpmuxRow | null {
  const items = row.items;
  if (!items?.some(isThought)) return row;
  const merged = mergeThoughts(items);
  const kept = merged.filter(
    (item, index) => !isThought(item) || !isQuietThought(item) || (keepLast && index === merged.length - 1),
  );
  if (kept.length === items.length && merged === items) return row;
  if (!kept.length) return null;
  return { ...row, items: kept, version: row.version + (keepLast ? 0.25 : 0.125) };
}

/// The transcript's rows with each step's consecutive thoughts merged and its quiet thoughts
/// (isQuietThought) left out; a step that held only quiet thoughts is left out whole. A thought
/// that may still stream stays (the live turn's "Thinking" line reads it): the last of a row the
/// turns mark `live`, or with `live` (the chat is working), the last of the last row. `rows` itself
/// when nothing changes.
export function withoutQuietThoughts(rows: AcpmuxRow[], live = false): AcpmuxRow[] {
  // The pane shapes its rows on every snapshot: the rows before the last are read again only after
  // the last one kept (prefixFlatMap.ts), so a snapshot costs the rows it changed. The last row
  // with `live` keeps its streaming thought and is shaped on its own.
  const split = live && rows.length > 0;
  const head = split ? rows.slice(0, -1) : rows;
  const read = quietReads.read(head);
  const last = split ? shapeRow(rows.at(-1)!, true) : undefined;
  const kept = quietOutputs.get(read);
  if (kept && kept.split === split && kept.last === last) return kept.out;
  let changed = read.items.length !== head.length || (split && last !== rows.at(-1));
  for (let index = 0; !changed && index < head.length; index += 1) changed = read.items[index] !== head[index];
  const out = changed ? (last ? [...read.items, last] : [...read.items]) : rows;
  quietOutputs.set(read, { split, last, out });
  return out;
}

/// One row as `withoutQuietThoughts` draws it: none for a step of quiet thoughts only.
function quietRow(row: AcpmuxRow): readonly AcpmuxRow[] {
  let next: AcpmuxRow | null;
  if (row.live === true) next = shapeRow(row, true);
  else if (shaped.has(row)) next = shaped.get(row)!;
  else {
    next = shapeRow(row, false);
    shaped.set(row, next);
  }
  return next ? [next] : [];
}

const quietReads = new PrefixFlatCache<AcpmuxRow, AcpmuxRow>(quietRow);
/// Each pass's answer, with the last row it was given (a pass with another last row answers again).
const quietOutputs = new WeakMap<
  PrefixFlat<AcpmuxRow, AcpmuxRow>,
  { split: boolean; last: AcpmuxRow | null | undefined; out: AcpmuxRow[] }
>();

/// One part of a thought's text: a heading line as its own title, or the text between headings.
export type ThoughtPart = { title: string } | { text: string };

/// A whole-line heading: Codex's reasoning summaries open each part with `**Heading**`, some models
/// with `# Heading`.
const HEADING = /^\s*(?:#{1,6}\s+(.+?)\s*#*|\*\*([^*]+?)\*\*)\s*$/;

/// A thought's text in parts: each heading line a title of its own, drawn without its marks (never
/// `**Heading**` in the text, never glued after "Thought"), and the text around it.
export function thoughtParts(text: string): ThoughtPart[] {
  const parts: ThoughtPart[] = [];
  let lines: string[] = [];
  const flush = () => {
    const chunk = lines.join("\n").replace(/^\n+|\s+$/g, "");
    if (chunk) parts.push({ text: chunk });
    lines = [];
  };
  for (const line of text.split("\n")) {
    const heading = HEADING.exec(line);
    const title = (heading?.[1] ?? heading?.[2])?.trim();
    if (!title) {
      lines.push(line);
      continue;
    }
    flush();
    parts.push({ title });
  }
  flush();
  return parts;
}

/// A thought's text as it draws: its headings without their marks, for Find's count.
export function drawnThought(text: string): string {
  const parts = thoughtParts(text);
  return parts.map((part) => ("title" in part ? part.title : part.text)).join("\n");
}
