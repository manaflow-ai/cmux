/**
 * Pure merge of the schema 3 field histograms for
 * `scripts/hang-reports-histograms.ts`. No I/O.
 *
 * Grouping. Buckets are summed per histogram name, app version and server
 * UTC day (`received_day`). A report's own `histograms[]` count under the
 * report's app version; each `launch_sections[]` entry counts under its
 * launch's profile version, since an earlier launch may have run an older
 * build. A section is counted once by its `id`: the client resends a section
 * whose upload it did not see succeed.
 *
 * Percentiles. Nearest rank over the merged buckets, read as the bucket's
 * upper bound, as Chrome's histogram percentiles are (and as the client's
 * `cmux metrics` reads them): at most 25% above the true value for a
 * log-linear layout. A rank in the overflow bucket, or in a Chromium bucket
 * whose upper end the report does not carry, is the bucket's lower bound and
 * is marked `atLeast`. An enumeration has no percentiles; its value counts
 * are listed instead.
 *
 * Nightly samples. `nightlyHistogramSamples` keeps what the merge drops: each
 * install's buckets per build, with every bucket's value range from the
 * catalog, for `scripts/cmux-next/field-histograms.py` (task 126), which
 * resamples installs for its bootstrap interval. Install ids become per-run
 * pseudonyms, so the export holds no stored identifier.
 */
import { bucketRange, histogramDefinition, type HistogramDefinition, type HistogramUnit } from "../../services/hangReports/histogramCatalog";
import { compareVersions } from "./topFrames";

export type StoredHistogram = {
  readonly name: string;
  readonly buckets: ReadonlyArray<readonly [number, number]>;
};

/** One `hang_reports` row as the script reads it. */
export type StoredFieldReport = {
  readonly installId: string;
  readonly receivedDay: string;
  readonly appVersion: string | null;
  /** The `app_build` column; the payload's `app.build` wins when present. */
  readonly appBuild?: string | null;
  readonly payload: {
    readonly schema?: number;
    readonly app?: { readonly version?: string; readonly build?: string };
    readonly histograms?: ReadonlyArray<StoredHistogram>;
    readonly launch_sections?: ReadonlyArray<{
      readonly id?: string;
      readonly profile?: { readonly version?: string; readonly build?: string };
      readonly histograms?: ReadonlyArray<StoredHistogram>;
    }>;
    readonly dropped?: {
      readonly histograms?: number;
      readonly stability?: number;
      readonly blackbox?: number;
      readonly labels?: number;
    };
  };
};

/** A percentile read from a bucket. */
export type PercentileValue = { readonly value: number; readonly atLeast: boolean };

export type MergedFieldHistogram = {
  readonly name: string;
  readonly version: string;
  readonly day: string;
  readonly unit: HistogramUnit | null;
  /** Samples summed over every report. */
  readonly count: number;
  /** Reports that carried the histogram, and their distinct installs. */
  readonly reports: number;
  readonly installs: number;
  /** Merged `[index, count]` pairs, ascending. */
  readonly buckets: ReadonlyArray<readonly [number, number]>;
  /** Null for an enumeration, a name this catalog does not know, or no samples. */
  readonly p50: PercentileValue | null;
  readonly p95: PercentileValue | null;
  readonly p99: PercentileValue | null;
};

export type DroppedTotals = {
  readonly histograms: number;
  readonly stability: number;
  readonly blackbox: number;
  readonly labels: number;
};

/** Export format of `nightlyHistogramSamples`, checked by field-histograms.py. */
export const NIGHTLY_EXPORT_FORMAT = "cmux-field-histograms/1";

/** One bucket with its catalog value range: `[low, high, count]`, `high` null for the overflow bucket. */
export type RangedBucket = readonly [number, number | null, number];

export type NightlyHistogram = {
  readonly name: string;
  readonly unit: HistogramUnit;
  readonly buckets: ReadonlyArray<RangedBucket>;
};

/** One install's buckets of one build: the unit of resampling in field-histograms.py. */
export type NightlyHistogramSample = {
  readonly install: string;
  readonly version: string;
  readonly build: string;
  readonly histograms: ReadonlyArray<NightlyHistogram>;
};

type SampleAccumulator = {
  readonly install: string;
  readonly version: string;
  readonly build: string;
  readonly names: Map<string, Map<number, number>>;
};

type Accumulator = {
  readonly name: string;
  readonly version: string;
  readonly day: string;
  readonly counts: Map<number, number>;
  reports: number;
  readonly installs: Set<string>;
};

const UNKNOWN_VERSION = "unknown";

/** Sum every schema 3 histogram by name, version and day, sorted by those keys. */
export function mergeFieldHistograms(reports: ReadonlyArray<StoredFieldReport>): MergedFieldHistogram[] {
  const groups = new Map<string, Accumulator>();
  forEachHistogramSource(reports, (report, version, _build, histograms) => addAll(groups, report, version, histograms));
  return [...groups.values()].sort(compareGroups).map(summarize);
}

/**
 * Each install's buckets per build, summed, for the histograms with ordered
 * values and known bucket ends (log-linear and linear layouts). A source
 * with no build cannot be placed in Nightly order and is left out, as is a
 * bucket no sample of the layout can take.
 */
export function nightlyHistogramSamples(reports: ReadonlyArray<StoredFieldReport>): NightlyHistogramSample[] {
  const pseudonyms = new Map<string, string>();
  const samples = new Map<string, SampleAccumulator>();
  forEachHistogramSource(reports, (report, version, build, histograms) => {
    if (build === null) return;
    let install = pseudonyms.get(report.installId);
    if (install === undefined) {
      install = `install-${pseudonyms.size + 1}`;
      pseudonyms.set(report.installId, install);
    }
    const key = `${install}\u0000${version}\u0000${build}`;
    let sample = samples.get(key);
    if (!sample) {
      sample = { install, version, build, names: new Map() };
      samples.set(key, sample);
    }
    addOrdered(sample.names, histograms);
  });
  return [...samples.values()].flatMap(({ install, version, build, names }) => {
    const histograms = [...names.entries()]
      .sort((a, b) => a[0].localeCompare(b[0]))
      .flatMap(([name, counts]) => rangedHistogram(name, counts) ?? []);
    return histograms.length > 0 ? [{ install, version, build, histograms }] : [];
  });
}

/** The names, keys and records ingest dropped, summed. */
export function droppedTotals(reports: ReadonlyArray<StoredFieldReport>): DroppedTotals {
  const total = { histograms: 0, stability: 0, blackbox: 0, labels: 0 };
  for (const report of reports) {
    total.histograms += report.payload.dropped?.histograms ?? 0;
    total.stability += report.payload.dropped?.stability ?? 0;
    total.blackbox += report.payload.dropped?.blackbox ?? 0;
    total.labels += report.payload.dropped?.labels ?? 0;
  }
  return total;
}

/** Nearest-rank percentile `fraction` (0 to 1) of `name`'s merged buckets. */
export function percentile(
  name: string,
  buckets: ReadonlyArray<readonly [number, number]>,
  fraction: number,
): PercentileValue | null {
  const definition = histogramDefinition(name);
  if (!definition || definition.layout.kind === "enumeration") return null;
  const total = buckets.reduce((sum, [, count]) => sum + count, 0);
  if (total === 0) return null;
  const rank = Math.max(1, Math.ceil(fraction * total));
  let seen = 0;
  for (const [index, count] of buckets) {
    seen += count;
    if (seen < rank) continue;
    const range = bucketRange(definition.layout, index);
    if (!range) return null;
    return range.high === null ? { value: range.low, atLeast: true } : { value: range.high, atLeast: false };
  }
  return null;
}

type HistogramSourceVisitor = (
  report: StoredFieldReport,
  version: string,
  build: string | null,
  histograms: ReadonlyArray<StoredHistogram>,
) => void;

/**
 * Every schema 3 histogram list once: a report's own under its app version
 * and build, each launch section under its profile's, a resent section once.
 */
function forEachHistogramSource(reports: ReadonlyArray<StoredFieldReport>, visit: HistogramSourceVisitor): void {
  const seenSections = new Set<string>();
  for (const report of reports) {
    if (report.payload.schema !== 3) continue;
    const version = report.payload.app?.version ?? report.appVersion ?? UNKNOWN_VERSION;
    visit(report, version, report.payload.app?.build ?? report.appBuild ?? null, report.payload.histograms ?? []);
    for (const section of report.payload.launch_sections ?? []) {
      const id = section.id?.toLowerCase();
      if (id !== undefined && seenSections.has(id)) continue;
      if (id !== undefined) seenSections.add(id);
      visit(report, section.profile?.version ?? UNKNOWN_VERSION, section.profile?.build ?? null, section.histograms ?? []);
    }
  }
}

/** The catalog entry of `name` when its values are ordered and every bucket's ends are known. */
function orderedDefinition(name: string): HistogramDefinition | null {
  const definition = histogramDefinition(name);
  if (!definition) return null;
  return definition.layout.kind === "logLinear" || definition.layout.kind === "linear" ? definition : null;
}

function addOrdered(names: Map<string, Map<number, number>>, histograms: ReadonlyArray<StoredHistogram>): void {
  for (const histogram of histograms) {
    if (orderedDefinition(histogram.name) === null) continue;
    let counts = names.get(histogram.name);
    if (!counts) {
      counts = new Map();
      names.set(histogram.name, counts);
    }
    for (const [index, count] of histogram.buckets) counts.set(index, (counts.get(index) ?? 0) + count);
  }
}

function rangedHistogram(name: string, counts: ReadonlyMap<number, number>): NightlyHistogram | null {
  const definition = orderedDefinition(name);
  if (!definition) return null;
  const buckets: RangedBucket[] = [];
  for (const [index, count] of [...counts.entries()].sort((a, b) => a[0] - b[0])) {
    const range = bucketRange(definition.layout, index);
    if (range) buckets.push([range.low, range.high, count]);
  }
  return buckets.length > 0 ? { name, unit: definition.unit, buckets } : null;
}

function addAll(
  groups: Map<string, Accumulator>,
  report: StoredFieldReport,
  version: string,
  histograms: ReadonlyArray<StoredHistogram>,
): void {
  for (const histogram of histograms) {
    const key = `${histogram.name}\u0000${version}\u0000${report.receivedDay}`;
    let group = groups.get(key);
    if (!group) {
      group = { name: histogram.name, version, day: report.receivedDay, counts: new Map(), reports: 0, installs: new Set() };
      groups.set(key, group);
    }
    group.reports += 1;
    group.installs.add(report.installId);
    for (const [index, count] of histogram.buckets) group.counts.set(index, (group.counts.get(index) ?? 0) + count);
  }
}

function summarize(group: Accumulator): MergedFieldHistogram {
  const buckets = [...group.counts.entries()].sort((a, b) => a[0] - b[0]);
  return {
    name: group.name,
    version: group.version,
    day: group.day,
    unit: histogramDefinition(group.name)?.unit ?? null,
    count: buckets.reduce((sum, [, count]) => sum + count, 0),
    reports: group.reports,
    installs: group.installs.size,
    buckets,
    p50: percentile(group.name, buckets, 0.5),
    p95: percentile(group.name, buckets, 0.95),
    p99: percentile(group.name, buckets, 0.99),
  };
}

function compareGroups(a: Accumulator, b: Accumulator): number {
  return a.name.localeCompare(b.name)
    || compareVersions(a.version, b.version)
    || a.version.localeCompare(b.version)
    || a.day.localeCompare(b.day);
}
