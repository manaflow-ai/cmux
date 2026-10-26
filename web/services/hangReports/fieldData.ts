import {
  histogramDefinition,
  isValidBucket,
  layoutCeiling,
  stabilityShape,
  type HistogramDefinition,
  type StabilityShape,
} from "./histogramCatalog";
import type { HangReport, HangReportHangV3, HangReportV3 } from "./wireSchema";
import {
  BLACKBOX_PHASES,
  BLACKBOX_PROCESSES,
  BLOCKING_CONTEXTS,
  BLOCKING_KINDS,
  INPUT_LABELS,
  SCROLL_JANK_NAMES,
  TASK_CLASSES,
  stabilityLeaves,
  type HangReportBlackboxEvent,
  type HangReportFieldHistogram,
  type HangReportInputLatencyRow,
  type HangReportScrollJank,
  type HangReportStability,
} from "./wireSchema3";

/**
 * What ingest left out of a schema 3 report, stored with it as `dropped`:
 * - `histograms`: well-formed names this server's catalog does not know (a
 *   newer client's catalog);
 * - `stability`: `stability{}` counts under a key or name this server does not know;
 * - `blackbox`: black-box records of a process or phase this server does not
 *   know, or that time a key or link one input across processes. The client
 *   never sends the latter (`TraceBlackBoxUpload.keeps`); the server drops
 *   them again so none is ever stored;
 * - `labels`: hang samples whose blocking kind or context, task classes,
 *   input latency rows and scroll jank histograms with a label this server
 *   does not know (the sample, the task, the row or the histogram is left out).
 */
export type DroppedFieldData = {
  readonly histograms: number;
  readonly stability: number;
  readonly blackbox: number;
  readonly labels: number;
};

/** Why a known histogram is refused: a client bug, not a newer catalog. */
export type FieldDataRefusal = "histogram_bucket" | "histogram_layout";

export type NormalizedReport =
  | { readonly ok: true; readonly report: HangReport; readonly dropped: DroppedFieldData | null }
  | { readonly ok: false; readonly reason: FieldDataRefusal };

// The client's per-input names (TraceBlackBoxUpload.perInputNames) and flow phases.
const PER_INPUT_NAMES: ReadonlySet<string> = new Set([
  "frame.present_estimate", "cef.host_input", "remote.input", "remote.present",
]);
const FLOW_PHASES: ReadonlySet<string> = new Set(["s", "f"]);

type Kept<T> = { readonly value: T; readonly dropped: number };
type KeptHistograms =
  | { readonly ok: true; readonly value: ReadonlyArray<HangReportFieldHistogram>; readonly dropped: number }
  | { readonly ok: false; readonly reason: FieldDataRefusal };

/**
 * Drop and count the names and labels this server does not know, and refuse
 * a known histogram whose unit, ceiling or buckets disagree with its catalog
 * layout. A schema 2 report passes through unchanged.
 */
export function normalizeFieldData(report: HangReport): NormalizedReport {
  if (report.schema !== 3) return { ok: true, report, dropped: null };
  const histograms = knownHistograms(report.histograms);
  if (!histograms.ok) return histograms;
  const sections = [];
  for (const section of report.launch_sections) {
    const kept = knownHistograms(section.histograms);
    if (!kept.ok) return kept;
    sections.push({ section: { ...section, histograms: kept.value }, histograms: kept.dropped, stability: knownStability(section.stability) });
  }
  const stability = knownStability(report.stability);
  const blackbox = report.blackbox.filter(isUploadable);
  const hangs = knownHangs(report.hangs);
  const inputLatency = knownInputLatency(report.input_latency);
  const scrollJank = knownScrollJank(report.scroll_jank);
  const kept: HangReportV3 = {
    ...report,
    hangs: hangs.value,
    histograms: histograms.value,
    stability: stability.value,
    blackbox,
    launch_sections: sections.map((entry) => ({ ...entry.section, stability: entry.stability.value })),
    ...(inputLatency.value === undefined ? {} : { input_latency: inputLatency.value }),
    ...(scrollJank.value === undefined ? {} : { scroll_jank: scrollJank.value }),
  };
  const dropped: DroppedFieldData = {
    histograms: histograms.dropped + sum(sections.map((entry) => entry.histograms)),
    stability: stability.dropped + sum(sections.map((entry) => entry.stability.dropped)),
    blackbox: report.blackbox.length - blackbox.length,
    labels: hangs.dropped + inputLatency.dropped + scrollJank.dropped,
  };
  return { ok: true, report: kept, dropped };
}

/** Total names, labels and records dropped, for the route's span. */
export function droppedTotal(dropped: DroppedFieldData | null): number {
  return dropped ? dropped.histograms + dropped.stability + dropped.blackbox + dropped.labels : 0;
}

function knownHistograms(histograms: ReadonlyArray<HangReportFieldHistogram>): KeptHistograms {
  const kept: HangReportFieldHistogram[] = [];
  for (const histogram of histograms) {
    const definition = histogramDefinition(histogram.name);
    if (!definition) continue;
    const refusal = layoutRefusal(definition, histogram);
    if (refusal) return { ok: false, reason: refusal };
    kept.push(histogram);
  }
  return { ok: true, value: kept, dropped: histograms.length - kept.length };
}

/** A known histogram must carry its catalog unit and ceiling (Chromium's own layout has neither) and valid buckets. */
function layoutRefusal(definition: HistogramDefinition, histogram: HangReportFieldHistogram): FieldDataRefusal | null {
  const ceiling = layoutCeiling(definition.layout);
  if (ceiling !== null && (histogram.unit !== definition.unit || histogram.max !== ceiling)) return "histogram_layout";
  return histogram.buckets.every(([index]) => isValidBucket(definition.layout, index)) ? null : "histogram_bucket";
}

function knownStability(stability: HangReportStability | null | undefined): Kept<HangReportStability | null> {
  if (stability == null) return { value: null, dropped: 0 };
  const kept: Record<string, HangReportStability[string]> = {};
  let dropped = 0;
  for (const [key, value] of Object.entries(stability)) {
    const shape = stabilityShape(key);
    const known = shape ? knownStabilityValue(shape, value) : null;
    if (known === null) {
      dropped += stabilityLeaves(value);
      continue;
    }
    kept[key] = known.value;
    dropped += known.dropped;
  }
  return { value: kept, dropped };
}

type StabilityValue = HangReportStability[string];
type CountMap = Readonly<Record<string, number>>;

/** `value` with its unknown names left out, or null when it is not the key's shape. */
function knownStabilityValue(shape: StabilityShape, value: StabilityValue): Kept<StabilityValue> | null {
  switch (shape.kind) {
    case "count":
      return typeof value === "number" ? { value, dropped: 0 } : null;
    case "map":
      return isCountMap(value) ? knownCounts(value, shape.keys) : null;
    case "nested": {
      if (typeof value === "number" || !Object.values(value).every(isCountMap)) return null;
      const kept: Record<string, CountMap> = {};
      let dropped = 0;
      for (const [outer, inner] of Object.entries(value as Readonly<Record<string, CountMap>>)) {
        const counts = shape.outer.has(outer) ? knownCounts(inner, shape.inner) : null;
        if (counts) kept[outer] = counts.value;
        dropped += counts ? counts.dropped : stabilityLeaves(inner);
      }
      return { value: kept, dropped };
    }
  }
}

function isCountMap(value: unknown): value is CountMap {
  return value !== null && typeof value === "object" && Object.values(value).every((count) => typeof count === "number");
}

function knownCounts(counts: CountMap, names: ReadonlySet<string>): Kept<CountMap> {
  const kept = Object.fromEntries(Object.entries(counts).filter(([name]) => names.has(name)));
  return { value: kept, dropped: Object.keys(counts).length - Object.keys(kept).length };
}

/** A detector sample of an unknown kind or context is left out; an unknown task class loses its task. */
function knownHangs(hangs: ReadonlyArray<HangReportHangV3>): Kept<ReadonlyArray<HangReportHangV3>> {
  const kept: HangReportHangV3[] = [];
  let dropped = 0;
  for (const hang of hangs) {
    if (hang.blocking && !(BLOCKING_KINDS.has(hang.blocking.kind) && BLOCKING_CONTEXTS.has(hang.blocking.context))) {
      dropped += 1;
    } else if (hang.task && !TASK_CLASSES.has(hang.task.class)) {
      dropped += 1;
      kept.push({ ...hang, task: null });
    } else {
      kept.push(hang);
    }
  }
  return { value: kept, dropped };
}

type InputLatencyRows = ReadonlyArray<HangReportInputLatencyRow> | null | undefined;

function knownInputLatency(rows: InputLatencyRows): Kept<InputLatencyRows> {
  if (rows == null) return { value: rows, dropped: 0 };
  const kept = rows.filter((row) => INPUT_LABELS.kind.has(row.kind) && INPUT_LABELS.target.has(row.target)
    && INPUT_LABELS.entrypoint.has(row.entrypoint) && INPUT_LABELS.presentation_source.has(row.presentation_source));
  return { value: kept, dropped: rows.length - kept.length };
}

function knownScrollJank(jank: HangReportScrollJank | null | undefined): Kept<HangReportScrollJank | null | undefined> {
  if (jank == null) return { value: jank, dropped: 0 };
  const histograms = jank.histograms.filter((histogram) => SCROLL_JANK_NAMES.has(histogram.name));
  return { value: { ...jank, histograms }, dropped: jank.histograms.length - histograms.length };
}

/** A known process and phase, and the client's `TraceBlackBoxUpload.keeps` rule for the fields the wire carries. */
function isUploadable(event: HangReportBlackboxEvent): boolean {
  if (!BLACKBOX_PROCESSES.has(event.process) || !BLACKBOX_PHASES.has(event.phase)) return false;
  if (FLOW_PHASES.has(event.phase) || PER_INPUT_NAMES.has(event.name) || event.name.startsWith("key.")) return false;
  return !event.name.split(/[._]/).includes("pty");
}

function sum(values: readonly number[]): number {
  return values.reduce((total, value) => total + value, 0);
}
