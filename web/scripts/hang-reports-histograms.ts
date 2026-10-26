/**
 * Field histograms from opt-in schema-3 cmux NEXT hang reports, exported for
 * the Nightly-to-Nightly comparison. Read only; run by hand, never in CI.
 *
 *   DATABASE_URL=... bun scripts/hang-reports-histograms.ts [--days 30] [--channel nightly] > nightlies.json
 *   python3 ../scripts/cmux-next/field-histograms.py nightlies.json
 *
 * Every query runs inside one `begin read only` transaction. Each report keeps
 * its build, day and install, because field-histograms.py resamples installs
 * for its bootstrap interval; install ids are replaced by per-run pseudonyms
 * so the file holds no stored identifier. Histograms are read from the
 * report's `histograms[]` and from each per-launch section's `histograms[]`
 * (p09-observability.md section 3D). Names outside the catalog pattern the
 * server accepts are dropped here too.
 */
import path from "node:path";
import { fileURLToPath } from "node:url";

import postgres from "postgres";

export const EXPORT_FORMAT = "cmux-hang-report-histograms/1";
const HISTOGRAM_SCHEMA = 3;
const NAME_PATTERN = /^[a-z0-9_.]{1,64}$/;
const UNIT_PATTERN = /^[a-z]{1,16}$/;

export type ExportedHistogram = {
  readonly name: string;
  readonly unit: string;
  readonly buckets: ReadonlyArray<readonly [number, number]>;
};

export type ExportedReport = {
  readonly install: string;
  readonly version: string | null;
  readonly build: string | null;
  readonly day: string;
  readonly histograms: readonly ExportedHistogram[];
};

export type StoredHistogramRow = {
  readonly install_id: string;
  readonly app_version: string | null;
  readonly app_build: string | null;
  readonly received_day: string | Date;
  readonly payload: unknown;
};

type Options = {
  readonly days: number;
  readonly channel: string;
};

function parseOptions(argv: readonly string[]): Options {
  const value = (flag: string): string | null => {
    const index = argv.indexOf(flag);
    if (index === -1) return null;
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) throw new Error(`${flag} needs a value`);
    return next;
  };
  const days = value("--days") ?? "30";
  if (!/^\d+$/.test(days) || Number(days) < 1) throw new Error("--days must be a positive integer");
  return { days: Number(days), channel: value("--channel") ?? "nightly" };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function bucketPairs(value: unknown): Array<readonly [number, number]> {
  if (!Array.isArray(value)) return [];
  const pairs: Array<readonly [number, number]> = [];
  for (const pair of value) {
    if (!Array.isArray(pair) || pair.length !== 2) continue;
    const [index, count] = pair;
    if (Number.isSafeInteger(index) && Number.isSafeInteger(count) && index >= 0 && count > 0) {
      pairs.push([index, count]);
    }
  }
  return pairs;
}

function histogramsOf(section: unknown): ExportedHistogram[] {
  if (!isRecord(section) || !Array.isArray(section.histograms)) return [];
  const histograms: ExportedHistogram[] = [];
  for (const histogram of section.histograms) {
    if (!isRecord(histogram)) continue;
    const { name, unit } = histogram;
    if (typeof name !== "string" || !NAME_PATTERN.test(name)) continue;
    if (typeof unit !== "string" || !UNIT_PATTERN.test(unit)) continue;
    const buckets = bucketPairs(histogram.buckets);
    if (buckets.length > 0) histograms.push({ name, unit, buckets });
  }
  return histograms;
}

function dayText(day: string | Date): string {
  return typeof day === "string" ? day.slice(0, 10) : day.toISOString().slice(0, 10);
}

/** Schema-3 rows as export reports; other schemas and rows with no histogram are left out. */
export function exportReports(rows: readonly StoredHistogramRow[]): ExportedReport[] {
  const pseudonyms = new Map<string, string>();
  const reports: ExportedReport[] = [];
  for (const row of rows) {
    if (!isRecord(row.payload) || row.payload.schema !== HISTOGRAM_SCHEMA) continue;
    const launches = Array.isArray(row.payload.launches) ? row.payload.launches : [];
    const histograms = [histogramsOf(row.payload), ...launches.map(histogramsOf)].flat();
    if (histograms.length === 0) continue;
    let install = pseudonyms.get(row.install_id);
    if (install === undefined) {
      install = `install-${pseudonyms.size + 1}`;
      pseudonyms.set(row.install_id, install);
    }
    reports.push({
      install,
      version: row.app_version,
      build: row.app_build,
      day: dayText(row.received_day),
      histograms,
    });
  }
  return reports;
}

async function loadRows(databaseURL: string, options: Options): Promise<StoredHistogramRow[]> {
  const sql = postgres(databaseURL, { max: 1 });
  try {
    return await sql.begin("read only", (tx) => tx<StoredHistogramRow[]>`
      select install_id, app_version, app_build, received_day, payload
      from hang_reports
      where received_at >= now() - make_interval(days => ${options.days})
        and channel = ${options.channel}
        and payload->>'schema' = ${String(HISTOGRAM_SCHEMA)}
    `);
  } finally {
    await sql.end();
  }
}

async function main(): Promise<void> {
  const options = parseOptions(process.argv.slice(2));
  const databaseURL = process.env.DATABASE_URL?.trim();
  if (!databaseURL) throw new Error("DATABASE_URL is required");
  const reports = exportReports(await loadRows(databaseURL, options));
  console.log(JSON.stringify({
    format: EXPORT_FORMAT,
    days: options.days,
    channel: options.channel,
    reports,
  }));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
