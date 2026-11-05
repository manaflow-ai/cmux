// A finished turn's waterfall (TurnWaterfall.tsx): each timed tool call and thought as a span on
// one time axis from the turn's start, so a slow turn shows where its time went. Pure, so the
// footer's toggle costs nothing until the reader opens it.
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { rowFailed } from "./toolFailure";
import { isDraftCall } from "./toolGroups";

/// The bar's tone: what kind of work the span was (TurnWaterfall.css).
export type WaterfallTone = "shell" | "read" | "edit" | "web" | "other" | "thought";

export type WaterfallSpan = {
  item: AcpmuxActivity;
  /// The call's id, which a tap on its bar opens; a thought has none.
  toolId?: string;
  tone: WaterfallTone;
  /// Offsets from the axis's start, in ms.
  from: number;
  to: number;
  failed: boolean;
};

export type Waterfall = {
  /// The axis: the turn's start to its end (or the last span's end, if later), in epoch ms.
  start: number;
  total: number;
  spans: WaterfallSpan[];
  /// The span that took longest, called out on its row; undefined with fewer than two spans.
  slowest?: number;
};

/// How many spans an opened waterfall draws before its "Show N more": a turn of hundreds of calls
/// opens in constant time, and the rest draw only when asked.
export const WATERFALL_FIRST = 40;

export function waterfallTone(item: AcpmuxActivity): WaterfallTone {
  const tool = item.tool;
  if (!tool) return "thought";
  switch (tool.kind) {
    case "execute":
      return tool.command ? "shell" : "other";
    case "read":
    case "search":
      return "read";
    case "edit":
    case "delete":
    case "move":
    case "fileChange":
      return "edit";
    case "fetch":
      return "web";
    default:
      return "other";
  }
}

/// The timed work of a turn's rows, in order: its tool calls (not the drafts the transcript hides,
/// turns.ts withoutDrafts) and its thoughts, each with a start and an end. Undefined when no call
/// was timed, so a footer carries nothing it cannot draw.
export function turnWork(rows: readonly AcpmuxRow[]): AcpmuxActivity[] | undefined {
  const work: AcpmuxActivity[] = [];
  let calls = 0;
  for (const row of rows) {
    if (row.kind !== "activity") continue;
    for (const item of row.items ?? []) {
      const span = item.tool ?? item;
      if (span.startedAt === undefined || span.endedAt === undefined) continue;
      if (item.tool) {
        if (isDraftCall(item.tool)) continue;
        calls += 1;
      } else if (item.kind !== "thought") continue;
      work.push(item);
    }
  }
  return calls ? work : undefined;
}

/// The footer's spans on one axis. The axis starts at the turn's start (its summary's time less its
/// duration), or at the first span when that came earlier, and ends at the turn's end or the last
/// span's end.
export function waterfall(row: Pick<AcpmuxRow, "at" | "durationMs">, work: readonly AcpmuxActivity[]): Waterfall {
  let first = Infinity;
  let last = -Infinity;
  for (const item of work) {
    const span = item.tool ?? item;
    first = Math.min(first, span.startedAt!);
    last = Math.max(last, span.endedAt!);
  }
  const start = row.durationMs !== undefined ? Math.min(first, row.at - row.durationMs) : first;
  const end = row.durationMs !== undefined ? Math.max(last, row.at) : last;
  const spans = work.map((item): WaterfallSpan => {
    const span = item.tool ?? item;
    const from = span.startedAt! - start;
    return {
      item,
      ...(item.tool?.id && { toolId: item.tool.id }),
      tone: waterfallTone(item),
      from,
      to: Math.max(from, span.endedAt! - start),
      failed: item.tool ? rowFailed(item.tool) : false,
    };
  });
  let slowest: number | undefined;
  if (spans.length > 1)
    spans.forEach((span, at) => {
      if (slowest === undefined || span.to - span.from > spans[slowest]!.to - spans[slowest]!.from) slowest = at;
    });
  return { start, total: Math.max(1, end - start), spans, ...(slowest !== undefined && { slowest }) };
}
