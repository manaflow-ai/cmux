/**
 * Pure merge of schema 3 field histograms for `scripts/hang-reports-histograms.ts`. No I/O.
 *
 * Grouping. One row per histogram name, app version and report day. A
 * report's own `histograms[]` count under its `app.version`; each earlier
 * launch in `launches[]` counts under that launch's own `app.version`
 * (Chrome keeps a persistent-histogram file's samples under the build that
 * recorded them, components/metrics/file_metrics_provider.cc).
 *
 * Merge. Bucket counts add per index, as Chrome's
 * `HistogramSamples::Add` does (base/metrics/histogram_samples.cc); count and
 * sum add, max is the largest.
 *
 * Percentiles. Linear interpolation inside the bucket that holds the rank,
 * over the bucket counts (the client sends at most 24 non-empty buckets, so
 * a histogram's `count` can be above its bucket total). The overflow bucket
 * ends at the merged max, and no estimate is above the merged max. Chromium
 * histograms (`chromium.*`) keep Chromium's own buckets, whose ranges the
 * server does not know: they get counts and no percentiles.
 */

import { HISTOGRAM_CATALOG, bucketRange, type HistogramUnit } from "../../services/hangReports/histogramCatalog";

export type StoredHistogram = {
  readonly name: string;
  readonly unit: string;
  readonly buckets: ReadonlyArray<readonly [number, number]>;
  readonly count: number;
  readonly sum: number;
  readonly max: number;
};

/** The schema 3 parts of one stored `hang_reports` payload that the merge reads. */
export type StoredHistogramReport = {
  readonly schema: number;
  readonly day: string;
  readonly app: { readonly version: string };
  readonly histograms?: readonly StoredHistogram[];
  readonly launches?: ReadonlyArray<{ readonly app: { readonly version: string }; readonly histograms?: readonly StoredHistogram[] }>;
};

export type MergedHistogram = {
  readonly name: string;
  readonly unit: HistogramUnit | null;
  readonly version: string;
  readonly day: string;
  /** Report sections (a report or one of its earlier launches) that sent this histogram. */
  readonly sections: number;
  readonly count: number;
  readonly sum: number;
  readonly max: number;
  readonly buckets: ReadonlyArray<readonly [number, number]>;
  readonly p50: number | null;
  readonly p95: number | null;
  readonly p99: number | null;
};

type Accumulator = {
  name: string;
  version: string;
  day: string;
  sections: number;
  count: number;
  sum: number;
  max: number;
  buckets: Map<number, number>;
};

function groupKey(name: string, version: string, day: string): string {
  return JSON.stringify([name, version, day]);
}

function add(groups: Map<string, Accumulator>, histogram: StoredHistogram, version: string, day: string): void {
  const key = groupKey(histogram.name, version, day);
  let group = groups.get(key);
  if (!group) {
    group = { name: histogram.name, version, day, sections: 0, count: 0, sum: 0, max: 0, buckets: new Map() };
    groups.set(key, group);
  }
  group.sections += 1;
  group.count += histogram.count;
  group.sum += histogram.sum;
  group.max = Math.max(group.max, histogram.max);
  for (const [index, count] of histogram.buckets) group.buckets.set(index, (group.buckets.get(index) ?? 0) + count);
}

/**
 * The value at quantile `q` (0 to 1) of bucket counts in a catalog layout,
 * or null for an unknown layout or an empty histogram.
 */
export function bucketPercentile(name: string, buckets: ReadonlyArray<readonly [number, number]>, max: number, q: number): number | null {
  const entry = HISTOGRAM_CATALOG.get(name);
  if (!entry) return null;
  const total = buckets.reduce((sum, [, count]) => sum + count, 0);
  if (total === 0) return null;
  const target = q * total;
  let before = 0;
  for (const [index, count] of buckets) {
    if (count === 0) continue;
    if (before + count >= target) {
      const range = bucketRange(entry.layout, index);
      if (!range) return null;
      const high = Number.isFinite(range.high) ? range.high : Math.max(range.low, max);
      const value = range.low + ((target - before) / count) * (high - range.low);
      return Math.min(value, max);
    }
    before += count;
  }
  return Math.min(max, before);
}

/** Merge every schema 3 histogram of `reports` per name, app version and report day. */
export function mergeHistograms(reports: readonly StoredHistogramReport[]): MergedHistogram[] {
  const groups = new Map<string, Accumulator>();
  for (const report of reports) {
    if (report.schema !== 3) continue;
    for (const histogram of report.histograms ?? []) add(groups, histogram, report.app.version, report.day);
    for (const launch of report.launches ?? []) {
      for (const histogram of launch.histograms ?? []) add(groups, histogram, launch.app.version, report.day);
    }
  }
  return [...groups.values()]
    .map((group) => {
      const buckets = [...group.buckets.entries()].sort((a, b) => a[0] - b[0]);
      return {
        name: group.name,
        unit: HISTOGRAM_CATALOG.get(group.name)?.unit ?? null,
        version: group.version,
        day: group.day,
        sections: group.sections,
        count: group.count,
        sum: group.sum,
        max: group.max,
        buckets,
        p50: bucketPercentile(group.name, buckets, group.max, 0.5),
        p95: bucketPercentile(group.name, buckets, group.max, 0.95),
        p99: bucketPercentile(group.name, buckets, group.max, 0.99),
      };
    })
    .sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version) || a.day.localeCompare(b.day));
}

/** Names dropped at ingest, summed over the stored `ingest` records. */
export function sumDrops(ingests: ReadonlyArray<{ readonly unknownHistograms?: number; readonly mismatchedHistograms?: number; readonly unknownStabilityKeys?: number } | null | undefined>) {
  let unknownHistograms = 0;
  let mismatchedHistograms = 0;
  let unknownStabilityKeys = 0;
  for (const ingest of ingests) {
    unknownHistograms += ingest?.unknownHistograms ?? 0;
    mismatchedHistograms += ingest?.mismatchedHistograms ?? 0;
    unknownStabilityKeys += ingest?.unknownStabilityKeys ?? 0;
  }
  return { unknownHistograms, mismatchedHistograms, unknownStabilityKeys };
}
