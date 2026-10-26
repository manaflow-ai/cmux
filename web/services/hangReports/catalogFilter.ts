import { HISTOGRAM_CATALOG, HISTOGRAM_CATALOG_VERSION, STABILITY_KEYS, maxBucketIndex } from "./histogramCatalog";
import type { HangReport, HangReportHistogram, HangReportLaunch, HangReportStability, HangReportV3 } from "./wireSchema";

/** What ingest dropped from a schema 3 report because the server catalog does not know it. */
export type CatalogDrops = {
  /** Histograms whose name is not in the server catalog. */
  readonly unknownHistograms: number;
  /** Catalog histograms sent with another unit, or a bucket index past the catalog layout. */
  readonly mismatchedHistograms: number;
  /** `stability{}` keys the server catalog does not know. */
  readonly unknownStabilityKeys: number;
};

/** The ingest record stored in the payload jsonb next to a schema 3 report. */
export type CatalogIngest = CatalogDrops & {
  /** The server catalog version the report was filtered with. */
  readonly catalogVersion: number;
};

export const NO_DROPS: CatalogDrops = { unknownHistograms: 0, mismatchedHistograms: 0, unknownStabilityKeys: 0 };

/** Total names a report lost to the catalog filter. */
export function droppedNames(drops: CatalogDrops): number {
  return drops.unknownHistograms + drops.mismatchedHistograms + drops.unknownStabilityKeys;
}

type Verdict = "keep" | "unknown" | "mismatched";

function histogramVerdict(histogram: HangReportHistogram): Verdict {
  const entry = HISTOGRAM_CATALOG.get(histogram.name);
  if (!entry) return "unknown";
  if (entry.unit !== histogram.unit) return "mismatched";
  const last = maxBucketIndex(entry.layout);
  if (last !== null && histogram.buckets.some(([index]) => index > last)) return "mismatched";
  return "keep";
}

type Tally = { unknownHistograms: number; mismatchedHistograms: number; unknownStabilityKeys: number };

function keepHistograms(histograms: readonly HangReportHistogram[], tally: Tally): HangReportHistogram[] {
  return histograms.filter((histogram) => {
    const verdict = histogramVerdict(histogram);
    if (verdict === "unknown") tally.unknownHistograms += 1;
    if (verdict === "mismatched") tally.mismatchedHistograms += 1;
    return verdict === "keep";
  });
}

function keepStability(stability: HangReportStability, tally: Tally): HangReportStability {
  const kept: Record<string, number> = {};
  for (const [key, count] of Object.entries(stability)) {
    if (STABILITY_KEYS.has(key)) kept[key] = count;
    else tally.unknownStabilityKeys += 1;
  }
  return kept;
}

/**
 * Drop every histogram and stability key of a schema 3 report that the
 * server catalog does not know, and count them. Chrome's UMA server does the
 * same with a histogram missing from histograms.xml: it is not shown, and
 * the log is not refused. A schema 2 report passes through unchanged.
 */
export function filterToCatalog(report: HangReport): { readonly report: HangReport; readonly drops: CatalogDrops } {
  if (report.schema !== 3) return { report, drops: NO_DROPS };
  const tally: Tally = { ...NO_DROPS };
  const launches: HangReportLaunch[] = report.launches.map((launch) => ({
    ...launch,
    histograms: keepHistograms(launch.histograms, tally),
    stability: keepStability(launch.stability, tally),
  }));
  const filtered: HangReportV3 = {
    ...report,
    histograms: keepHistograms(report.histograms, tally),
    stability: keepStability(report.stability, tally),
    launches,
  };
  return { report: filtered, drops: tally };
}

/** The ingest record for a filtered report. */
export function catalogIngest(drops: CatalogDrops): CatalogIngest {
  return { catalogVersion: HISTOGRAM_CATALOG_VERSION, ...drops };
}

/** A key-category trace record (`key.*`): per-key timing that must never leave the Mac. */
export function hasKeyRecord(report: HangReport): boolean {
  return report.schema === 3 && report.blackbox.some((event) => event.name === "key" || event.name.startsWith("key."));
}
