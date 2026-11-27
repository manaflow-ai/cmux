// A finished turn's waterfall (TurnWaterfall.tsx): each timed tool call and thought as a span on
// one time axis from the turn's start, so a slow turn shows where its time went. Pure, so the
// footer's toggle costs nothing until the reader opens it.
import type { AcpmuxActivity, AcpmuxModelCall, AcpmuxRow } from "../model";
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
  /// The stretches of the axis no span covers, as offsets in ms: the model reading, deciding and
  /// writing its reply with no tool or thought running. Without them a turn of one 2.7s call on a
  /// 14.1s axis drew most of its time as nothing (Leo, 2026-11-05: "im not sure what the total thing
  /// is meant to represent").
  gaps: { from: number; to: number }[];
  /// The gaps' sum: the spans' union and this make the whole axis.
  gapTotal: number;
};

/// The stretches of [0, total] that no span covers, in order.
export function waterfallGaps(
  spans: readonly Pick<WaterfallSpan, "from" | "to">[],
  total: number,
): { from: number; to: number }[] {
  const gaps: { from: number; to: number }[] = [];
  let covered = 0;
  for (const span of [...spans].sort((a, b) => a.from - b.from)) {
    if (span.from > covered) gaps.push({ from: covered, to: span.from });
    covered = Math.max(covered, span.to);
  }
  if (covered < total) gaps.push({ from: covered, to: total });
  return gaps;
}

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

const endsKeys = new WeakMap<readonly AcpmuxActivity[], string>();

/// Where and how `work`'s background shells ended, exactly: a shell that ends after its turn's
/// summary changes only its activity row, never the footer's version, so the footer's memo
/// (rows/SummaryRow.tsx) compares this too and its Timeline redraws. Kept per work array, which a
/// footer holds until its turn's rows change.
export function workEnds(work: readonly AcpmuxActivity[] | undefined): string {
  if (!work) return "";
  let key = endsKeys.get(work);
  if (key === undefined) {
    key = work
      .map((item) => {
        const background = item.tool?.background;
        return background?.endedAt === undefined ? "" : `${background.endedAt}:${background.state}`;
      })
      .join(",");
    endsKeys.set(work, key);
  }
  return key;
}

/// A Timeline span's kind for one model call acpmux timed (claude_stdio/model_calls.rs).
export const MODEL_CALL = "model";

/// A model call as a span: from its request to its last token, the model's whole time on it,
/// "from anthropic and back" (Leo, 2026-11-27, on a Timeline that read "Thinking 3ms").
function modelCallItem(call: AcpmuxModelCall): AcpmuxActivity {
  return {
    kind: MODEL_CALL,
    text: "",
    startedAt: call.requestAt ?? call.firstTokenAt,
    endedAt: call.lastTokenAt,
    firstTokenAt: call.firstTokenAt,
    ...(call.thought && { thought: true }),
  };
}

/// The timed work of a turn's rows, in order: its tool calls (not the drafts the transcript hides,
/// turns.ts withoutDrafts), and its model calls as acpmux timed them (`modelCallItem`), each with a
/// start and an end. A turn whose daemon timed no call (an older one, another harness) has its
/// thoughts instead, timed from their first chunk to their last: Claude Code's thinking comes in
/// one burst at its call's end, so those measure milliseconds of a call's seconds. Undefined when
/// nothing was timed, so a footer carries nothing it cannot draw.
export function turnWork(rows: readonly AcpmuxRow[]): AcpmuxActivity[] | undefined {
  const timed = rows.some((row) => row.modelCalls?.length);
  const work: AcpmuxActivity[] = [];
  for (const row of rows) {
    if (row.kind === "activity")
      for (const item of row.items ?? []) {
        const [from, to] = spanTimes(item);
        if (from === undefined || to === undefined) continue;
        if (item.tool ? isDraftCall(item.tool) : timed || item.kind !== "thought") continue;
        work.push(item);
      }
    for (const call of row.modelCalls ?? []) work.push(modelCallItem(call));
  }
  // In the order they ran: a row's calls ended after the work it shows began.
  if (timed) work.sort((a, b) => spanTimes(a)[0]! - spanTimes(b)[0]!);
  return work.length ? work : undefined;
}

/// The footer's spans on one axis. The axis starts at the turn's start (where its work ended less its
/// duration), or at the first span when that came earlier, and ends at the turn's end or the last
/// span's end. Its work ended at its own time, or later for a stretch the person came in on, which
/// worked until his steer (model.ts `workEndedAt`).
export function waterfall(
  row: Pick<AcpmuxRow, "at" | "durationMs" | "workEndedAt">,
  work: readonly AcpmuxActivity[],
): Waterfall {
  let first = Infinity;
  let last = -Infinity;
  for (const item of work) {
    const [from, to] = spanTimes(item);
    first = Math.min(first, from!);
    last = Math.max(last, to!);
  }
  const ended = row.workEndedAt ?? row.at;
  const start = row.durationMs !== undefined ? Math.min(first, ended - row.durationMs) : first;
  const end = row.durationMs !== undefined ? Math.max(last, ended) : last;
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
  const total = Math.max(1, end - start);
  const gaps = waterfallGaps(spans, total);
  const gapTotal = gaps.reduce((sum, gap) => sum + gap.to - gap.from, 0);
  return { start, total, spans, ...(slowest !== undefined && { slowest }), gaps, gapTotal };
}

/// A bar under this share of the axis is a tick, not a bar: it shows a call happened, not how long.
export const WATERFALL_VISIBLE_BAR = 0.02;

/// Whether a turn's Timeline is worth a chart (Leo, 2026-11-22, on "1 call · 1m 40s" drawn as a
/// 551ms tick, one 24.5s bar and 1m 15s of stripes: "IF THIS IS THE CASE, THEN DON'T FUCKING DISPLAY
/// THIS BULLSHIT LIKE THIS"). A chart compares bars on one axis, so it needs two or more tool calls
/// whose bars are visible (each at least 2% of the axis), and the model's time outside every call
/// and thought under half the turn. Anything else (a lone call, a turn that only thought, a turn
/// that was mostly the model) reads as plain lines instead (`waterfallLines`).
export function waterfallCharts(chart: Pick<Waterfall, "spans" | "total" | "gapTotal">): boolean {
  if (chart.gapTotal * 2 >= chart.total) return false;
  let visible = 0;
  for (const span of chart.spans)
    if (span.item.tool && span.to - span.from >= chart.total * WATERFALL_VISIBLE_BAR && ++visible >= 2) return true;
  return false;
}

/// One line of the plain form: a call with its own time, or (no span) the turn's thinking.
export type WaterfallLine = { span?: WaterfallSpan; ms: number };

/// The plain form's lines: one "Thinking" line for the model's time, then each call with its own
/// time, in the order they ran. The model's time is its timed calls' (`modelCallItem`, request to last
/// token) when acpmux timed them, else all of the turn's time with no tool running (its thoughts and
/// the model's time around them, which the chart split into a tick and a striped row). Under 1ms of
/// thinking is no line.
export function waterfallLines(chart: Pick<Waterfall, "spans" | "total">): WaterfallLine[] {
  const calls = chart.spans.filter((span) => span.item.tool);
  const models = chart.spans.filter((span) => span.item.kind === MODEL_CALL);
  const thinking = models.length
    ? models.reduce((sum, span) => sum + span.to - span.from, 0)
    : waterfallGaps(calls, chart.total).reduce((sum, gap) => sum + gap.to - gap.from, 0);
  const lines: WaterfallLine[] = thinking >= 1 ? [{ ms: thinking }] : [];
  for (const span of calls) lines.push({ span, ms: span.to - span.from });
  return lines;
}
