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
  /// The call that took longest, called out on its row (never a thought: the tag says which call
  /// to look at); undefined with fewer than two calls.
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

/// When a span began and ended: a shell that went on in the background ran until it ended there
/// (toolGroups.ts toolDuration); a thought, from its first chunk to its latest.
function spanTimes(item: AcpmuxActivity): [number | undefined, number | undefined] {
  const tool = item.tool;
  if (!tool) return [item.startedAt, item.endedAt];
  return [tool.startedAt, tool.background ? tool.background.endedAt : tool.endedAt];
}

/// Failed by its status or exit, or in the background by how it ended there.
const spanFailed = (item: AcpmuxActivity) =>
  item.tool ? rowFailed(item.tool) || item.tool.background?.state === "failed" : false;

/// Where `work`'s background shells ended, in one number under 64: a late end changes it, so the
/// footer that carries the work takes a new version (turns.ts shapeTurn) and its Timeline redraws.
/// It mixes each end's time with its place, so a new end moves it unless by chance, where a bare
/// count of the ends came back to the same number after every 64.
export function workEnds(work: readonly AcpmuxActivity[] | undefined): number {
  let hash = 0;
  work?.forEach((item, at) => {
    const end = item.tool?.background?.endedAt;
    if (end !== undefined) hash = (hash * 31 + end + at + 1) % 2_147_483_647;
  });
  return hash % 64;
}

/// The timed work of a turn's rows, in order: its tool calls (not the drafts the transcript hides,
/// turns.ts withoutDrafts) and its thoughts, each with a start and an end. Undefined when nothing
/// was timed, so a footer carries nothing it cannot draw.
export function turnWork(rows: readonly AcpmuxRow[]): AcpmuxActivity[] | undefined {
  const work: AcpmuxActivity[] = [];
  for (const row of rows) {
    if (row.kind !== "activity") continue;
    for (const item of row.items ?? []) {
      const [from, to] = spanTimes(item);
      if (from === undefined || to === undefined) continue;
      if (item.tool ? isDraftCall(item.tool) : item.kind !== "thought") continue;
      work.push(item);
    }
  }
  return work.length ? work : undefined;
}

/// The footer's spans on one axis. The axis starts at the turn's start (its summary's time less its
/// duration), or at the first span when that came earlier, and ends at the turn's end or the last
/// span's end.
export function waterfall(row: Pick<AcpmuxRow, "at" | "durationMs">, work: readonly AcpmuxActivity[]): Waterfall {
  let first = Infinity;
  let last = -Infinity;
  for (const item of work) {
    const [from, to] = spanTimes(item);
    first = Math.min(first, from!);
    last = Math.max(last, to!);
  }
  const start = row.durationMs !== undefined ? Math.min(first, row.at - row.durationMs) : first;
  const end = row.durationMs !== undefined ? Math.max(last, row.at) : last;
  const spans = work.map((item): WaterfallSpan => {
    const [began, ended] = spanTimes(item);
    const from = began! - start;
    return {
      item,
      ...(item.tool?.id && { toolId: item.tool.id }),
      tone: waterfallTone(item),
      from,
      to: Math.max(from, ended! - start),
      failed: spanFailed(item),
    };
  });
  let slowest: number | undefined;
  if (spans.filter((span) => span.item.tool).length > 1)
    spans.forEach((span, at) => {
      if (!span.item.tool) return;
      if (slowest === undefined || span.to - span.from > spans[slowest]!.to - spans[slowest]!.from) slowest = at;
    });
  return { start, total: Math.max(1, end - start), spans, ...(slowest !== undefined && { slowest }) };
}
