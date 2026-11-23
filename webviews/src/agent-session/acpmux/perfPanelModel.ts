// What the Inspector's Perf tab draws from the perf watch's event stream (acpmux perf_watch.rs,
// `_acpmux/perf {op:"read"}`): notes newest first, spans as a waterfall and the data meter's hot
// zones. Pure, so the tab and its tests share it.
import type { Translate } from "./i18n";

/** Events the tab keeps at most; the oldest go first. */
export const EVENTS_KEPT = 500;
/** Spans the tab draws at most, newest first. */
export const SPANS_SHOWN = 100;
/** How long one `read` waits for the next event. */
export const READ_WAIT_MS = 20_000;

export type PerfPartEvent = { name: string; startMs: number; ms: number };
export type PerfSpanEvent = {
  kind: "span";
  seq: number;
  at: number;
  name: string;
  ms: number;
  budgetMs?: number | null;
  over?: boolean;
  parts?: PerfPartEvent[];
  detail?: unknown;
};
export type PerfNoteEvent = {
  kind: "note";
  seq: number;
  at: number;
  text: string;
  key?: string;
  quietedBefore?: number;
  detail?: unknown;
};
export type MeterZone = {
  channel: string;
  label: string;
  bytesPerMinute: number;
  bytes: number;
  count?: number;
  largest: number;
};
export type PerfMeterEvent = { kind: "meter"; seq: number; at: number; top: MeterZone[] };
export type PerfEvent = PerfSpanEvent | PerfNoteEvent | PerfMeterEvent | { kind: string; seq: number; at: number };

/** The daemon's `status` and `read` answers: whether the watch is on, and its newest seq. */
export type PerfStatus = { on: boolean; seq: number };

const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

export function perfStatus(answer: unknown): PerfStatus {
  const value = (answer ?? {}) as { on?: unknown; seq?: unknown };
  return { on: value.on === true, seq: finite(value.seq) ? value.seq : 0 };
}

/** The events of a `read` answer that have a kind and a seq. */
export function readEvents(answer: unknown): PerfEvent[] {
  const events = (answer as { events?: unknown } | null)?.events;
  if (!Array.isArray(events)) return [];
  return events.filter(
    (event): event is PerfEvent =>
      !!event && typeof event === "object" && typeof event.kind === "string" && finite(event.seq),
  );
}

/** Where the next `read` starts: after the last event read, or after the answer's seq when none came. */
export function nextAfter(after: number, answer: unknown, events: readonly PerfEvent[]): number {
  const last = events.at(-1)?.seq;
  if (last !== undefined) return last;
  const { seq } = perfStatus(answer);
  // A seq behind the cursor: the watch started again (its count restarts), so read it from the start.
  return seq < after ? 0 : seq;
}

/**
 * `kept` with `incoming` after it, at most EVENTS_KEPT, oldest dropped. Events at or before the
 * last kept seq mean the watch started again (its count restarts): they replace what was kept.
 */
export function appendEvents(kept: readonly PerfEvent[], incoming: readonly PerfEvent[]): PerfEvent[] {
  if (!incoming.length) return kept as PerfEvent[];
  const last = kept.at(-1)?.seq ?? -1;
  const merged = incoming[0]!.seq <= last ? [...incoming] : [...kept, ...incoming];
  return merged.length > EVENTS_KEPT ? merged.slice(-EVENTS_KEPT) : merged;
}

export function notesOf(events: readonly PerfEvent[]): PerfNoteEvent[] {
  return events.filter((event): event is PerfNoteEvent => event.kind === "note").reverse();
}

export function spansOf(events: readonly PerfEvent[]): PerfSpanEvent[] {
  return events
    .filter((event): event is PerfSpanEvent => event.kind === "span")
    .reverse()
    .slice(0, SPANS_SHOWN);
}

/** The newest meter summary's hot zones. */
export function meterOf(events: readonly PerfEvent[]): MeterZone[] {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]!;
    if (event.kind === "meter" && Array.isArray((event as PerfMeterEvent).top)) return (event as PerfMeterEvent).top;
  }
  return [];
}

export type WaterfallBar = { name: string; ms: number; left: number; width: number };
export type Waterfall = { bars: WaterfallBar[]; budgetAt?: number; over: boolean };

/**
 * One span's bars, in percent of its row: each part offset by its `startMs`, all scaled to the span's
 * total (or the last part's end, when a part runs past it). `budgetAt` is the budget's place on the
 * same scale when it falls inside the row.
 */
export function waterfall(span: Pick<PerfSpanEvent, "ms" | "budgetMs" | "over" | "parts">): Waterfall {
  const parts = (span.parts ?? []).filter((part) => finite(part.startMs) && finite(part.ms));
  const scale = Math.max(1, finite(span.ms) ? span.ms : 0, ...parts.map((part) => part.startMs + part.ms));
  const percent = (ms: number) => Math.round((Math.max(0, ms) / scale) * 1000) / 10;
  const bars = parts.length
    ? parts.map((part) => ({
        name: part.name,
        ms: part.ms,
        left: percent(part.startMs),
        width: Math.max(0.5, percent(part.ms)),
      }))
    : [{ name: "", ms: span.ms, left: 0, width: percent(span.ms) }];
  const budget = finite(span.budgetMs) && span.budgetMs > 0 ? percent(span.budgetMs) : undefined;
  const over = span.over ?? (budget !== undefined && finite(span.budgetMs) && span.ms > span.budgetMs);
  return { bars, budgetAt: budget !== undefined && budget <= 100 ? budget : undefined, over };
}

/** A byte count as B, KB or MB. */
export function byteText(bytes: number, t: Translate): string {
  if (bytes < 1024) return t("inspector.bytes", { value: Math.round(bytes) });
  if (bytes < 1024 * 1024) return t("inspector.kilobytes", { value: (bytes / 1024).toFixed(1) });
  return t("inspector.megabytes", { value: (bytes / (1024 * 1024)).toFixed(1) });
}

/** A duration in ms, a tenth below 10 ms. */
export function msText(ms: number, t: Translate): string {
  return t("inspector.milliseconds", { value: ms < 10 ? ms.toFixed(1) : Math.round(ms) });
}
