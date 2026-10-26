/**
 * Field-histogram percentiles from opt-in cmux NEXT schema 3 hang reports. Read only.
 *
 *   DATABASE_URL=... bun scripts/hang-reports-histograms.ts [--days 7] [--channel nightly]
 *     [--name key.frame] [--json]
 *
 * Prints p50, p95 and p99 per histogram name, app version and report day,
 * and the names ingest dropped as outside the server catalog. Every query
 * runs inside one `begin read only` transaction. Merge and percentile rules
 * live in `scripts/hang-reports/histograms.ts`. `--name` keeps the names
 * that start with its value.
 */
import postgres from "postgres";

import { mergeHistograms, sumDrops, type MergedHistogram, type StoredHistogramReport } from "./hang-reports/histograms";

type Options = {
  readonly days: number;
  readonly channel: string | null;
  readonly name: string | null;
  readonly json: boolean;
};

type StoredIngest = Parameters<typeof sumDrops>[0][number];
type Row = { readonly payload: StoredHistogramReport & { readonly ingest?: StoredIngest } };

function parseOptions(argv: readonly string[]): Options {
  const value = (flag: string): string | null => {
    const index = argv.indexOf(flag);
    if (index === -1) return null;
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) throw new Error(`${flag} needs a value`);
    return next;
  };
  const days = value("--days") ?? "7";
  if (!/^\d+$/.test(days) || Number(days) < 1) throw new Error("--days must be a positive integer");
  return { days: Number(days), channel: value("--channel"), name: value("--name"), json: argv.includes("--json") };
}

async function loadRows(databaseURL: string, options: Options): Promise<Row[]> {
  const sql = postgres(databaseURL, { max: 1 });
  try {
    return await sql.begin("read only", (tx) => tx<Row[]>`
      select payload
      from hang_reports
      where received_at >= now() - make_interval(days => ${options.days})
        and payload->>'schema' = '3'
        ${options.channel ? tx`and channel = ${options.channel}` : tx``}
    `);
  } finally {
    await sql.end();
  }
}

function formatValue(value: number | null): string {
  if (value === null) return "n/a";
  return value >= 100 ? String(Math.round(value)) : value.toFixed(2);
}

function printText(rows: readonly Row[], merged: readonly MergedHistogram[], options: Options): void {
  const drops = sumDrops(rows.map((row) => row.payload.ingest));
  console.log(`${rows.length} schema 3 reports, last ${options.days} days`);
  console.log(`dropped at ingest: ${drops.unknownHistograms} unknown histograms, ${drops.mismatchedHistograms} mismatched, ${drops.unknownStabilityKeys} unknown stability keys`);
  console.log("");
  console.log(["name", "version", "day", "unit", "count", "p50", "p95", "p99", "max"].join("\t"));
  for (const histogram of merged) {
    console.log([
      histogram.name,
      histogram.version,
      histogram.day,
      histogram.unit ?? "?",
      histogram.count,
      formatValue(histogram.p50),
      formatValue(histogram.p95),
      formatValue(histogram.p99),
      histogram.max,
    ].join("\t"));
  }
}

async function main(): Promise<void> {
  const options = parseOptions(process.argv.slice(2));
  const databaseURL = process.env.DATABASE_URL?.trim();
  if (!databaseURL) throw new Error("DATABASE_URL is required");
  const rows = await loadRows(databaseURL, options);
  const merged = mergeHistograms(rows.map((row) => row.payload))
    .filter((histogram) => !options.name || histogram.name.startsWith(options.name));
  if (options.json) {
    console.log(JSON.stringify({
      reports: rows.length,
      dropped: sumDrops(rows.map((row) => row.payload.ingest)),
      histograms: merged,
    }, null, 2));
    return;
  }
  printText(rows, merged, options);
}

await main();
