import { histogramDefinition, isKnownStabilityKey, isValidBucket } from "./histogramCatalog";
import type {
  HangReport,
  HangReportBlackboxEvent,
  HangReportHistogram,
  HangReportLaunchSection,
  HangReportStability,
  HangReportV3,
} from "./wireSchema";

/**
 * What ingest left out of a schema 3 report, stored with it as `dropped`:
 * - `histograms`: well-formed names this server's catalog does not know (a
 *   client with a newer `catalog_version`);
 * - `stability`: `stability{}` keys this server does not know;
 * - `blackbox`: black-box records that time a key or link one input across
 *   processes. The client never sends them (`TraceBlackBoxUpload.keeps`);
 *   the server drops them again so none is ever stored.
 */
export type DroppedFieldData = {
  readonly histograms: number;
  readonly stability: number;
  readonly blackbox: number;
};

export type NormalizedReport =
  | { readonly ok: true; readonly report: HangReport; readonly dropped: DroppedFieldData | null }
  | { readonly ok: false; readonly reason: "histogram_bucket" };

// The client's per-input names (TraceBlackBoxUpload.perInputNames) and flow phases.
const PER_INPUT_NAMES: ReadonlySet<string> = new Set([
  "frame.present_estimate", "cef.host_input", "remote.input", "remote.present",
]);
const FLOW_PHASES: ReadonlySet<string> = new Set(["s", "f"]);

/**
 * Drop and count the names this server does not know, and refuse a known
 * histogram with a bucket its layout cannot hold (a client bug, not a newer
 * catalog). A schema 2 report passes through unchanged.
 */
export function normalizeFieldData(report: HangReport): NormalizedReport {
  if (report.schema !== 3) return { ok: true, report, dropped: null };
  const current = fieldData(report.histograms, report.stability);
  const sections = report.sections.map((section) => ({ section, data: fieldData(section.histograms, section.stability) }));
  if (current === null || sections.some((entry) => entry.data === null)) return { ok: false, reason: "histogram_bucket" };
  const blackbox = report.blackbox.filter(isUploadable);
  const kept: HangReportV3 = {
    ...report,
    histograms: current.histograms,
    stability: current.stability,
    blackbox,
    sections: sections.map(({ section, data }): HangReportLaunchSection => ({
      ...section,
      histograms: data?.histograms ?? [],
      stability: data?.stability ?? null,
    })),
  };
  const dropped: DroppedFieldData = {
    histograms: current.droppedHistograms + sum(sections.map((entry) => entry.data?.droppedHistograms ?? 0)),
    stability: current.droppedStability + sum(sections.map((entry) => entry.data?.droppedStability ?? 0)),
    blackbox: report.blackbox.length - blackbox.length,
  };
  return { ok: true, report: kept, dropped };
}

/** Total names and records dropped, for the route's span. */
export function droppedTotal(dropped: DroppedFieldData | null): number {
  return dropped ? dropped.histograms + dropped.stability + dropped.blackbox : 0;
}

type FieldData = {
  readonly histograms: ReadonlyArray<HangReportHistogram>;
  readonly stability: HangReportStability | null;
  readonly droppedHistograms: number;
  readonly droppedStability: number;
};

function fieldData(
  histograms: ReadonlyArray<HangReportHistogram>,
  stability: HangReportStability | null | undefined,
): FieldData | null {
  const known = histograms.filter((histogram) => histogramDefinition(histogram.name) !== null);
  if (!known.every(hasValidBuckets)) return null;
  const entries = Object.entries(stability ?? {});
  const keptStability = entries.filter(([key]) => isKnownStabilityKey(key));
  return {
    histograms: known,
    stability: stability == null ? null : Object.fromEntries(keptStability),
    droppedHistograms: histograms.length - known.length,
    droppedStability: entries.length - keptStability.length,
  };
}

function hasValidBuckets(histogram: HangReportHistogram): boolean {
  const definition = histogramDefinition(histogram.name);
  return definition !== null && histogram.buckets.every(([index]) => isValidBucket(definition.layout, index));
}

/** The client's `TraceBlackBoxUpload.keeps` rule, for the fields the wire carries. */
function isUploadable(event: HangReportBlackboxEvent): boolean {
  if (FLOW_PHASES.has(event.phase) || PER_INPUT_NAMES.has(event.name) || event.name.startsWith("key.")) return false;
  return !event.name.split(/[._]/).includes("pty");
}

function sum(values: readonly number[]): number {
  return values.reduce((total, value) => total + value, 0);
}
