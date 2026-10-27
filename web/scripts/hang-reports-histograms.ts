/**
 * Field histogram percentiles from opt-in cmux NEXT hang reports (schema 3).
 * Read only.
 *
 *   DATABASE_URL=... bun scripts/hang-reports-histograms.ts [--days 7] [--channel nightly]
 *     [--name key.frame.] [--json]
 *
 * Prints p50/p95/p99 per histogram name, app version and server UTC day.
 * Every query runs inside one `begin read only` transaction. Merge and
 * percentile rules live in `scripts/hang-reports/histograms.ts`.
 */
import postgres from "postgres";

import {
  droppedTotals,
  mergeFieldHistograms,
  type MergedFieldHistogram,
  type PercentileValue,
  type StoredFieldReport,
} from "./hang-reports/histograms";

type Options = {
  readonly days: number;
  readonly channel: string | null;
  readonly namePrefix: string | null;
  readonly json: boolean;
};

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
  return { days: Number(days), channel: value("--channel"), namePrefix: value("--name"), json: argv.includes("--json") };
}

async function loadReports(databaseURL: string, options: Options): Promise<StoredFieldReport[]> {
  const sql = postgres(databaseURL, { max: 1 });
  try {
    const rows = await sql.begin("read only", (tx) => tx<{
      install_id: string;
      received_day: string;
      app_version: string | null;
      payload: StoredFieldReport["payload"];
    }[]>`
      select install_id, received_day::text as received_day, app_version, payload
      from hang_reports
      where received_at >= now() - make_interval(days => ${options.days})
        and payload->>'schema' = '3'
        ${options.channel ? tx`and channel = ${options.channel}` : tx``}
    `);
    return rows.map((row) => ({
      installId: row.install_id,
      receivedDay: row.received_day,
      appVersion: row.app_version,
      payload: row.payload,
    }));
  } finally {
    await sql.end();
  }
}

function formatPercentile(value: PercentileValue | null): string {
  if (!value) return "-";
  return value.atLeast ? `>=${value.value}` : String(value.value);
}

function printText(reports: readonly StoredFieldReport[], merged: readonly MergedFieldHistogram[], options: Options): void {
  const dropped = droppedTotals(reports);
  console.log(`${reports.length} schema 3 reports, last ${options.days} days`);
  console.log(`dropped at ingest: ${dropped.histograms} histograms, ${dropped.stability} stability counts, ${dropped.blackbox} black-box records, ${dropped.labels} unknown labels`);
  console.log("");
  console.log(["name", "version", "day", "unit", "count", "installs", "p50", "p95", "p99"].join("\t"));
  for (const row of merged) {
    const values = row.p50 === null && row.unit === "enum"
      ? [row.buckets.map(([value, count]) => `${value}:${count}`).join(" "), "", ""]
      : [formatPercentile(row.p50), formatPercentile(row.p95), formatPercentile(row.p99)];
    console.log([row.name, row.version, row.day, row.unit ?? "?", row.count, row.installs, ...values].join("\t"));
  }
}

async function main(): Promise<void> {
  const options = parseOptions(process.argv.slice(2));
  const databaseURL = process.env.DATABASE_URL?.trim();
  if (!databaseURL) throw new Error("DATABASE_URL is required");
  const reports = await loadReports(databaseURL, options);
  const merged = mergeFieldHistograms(reports)
    .filter((row) => !options.namePrefix || row.name.startsWith(options.namePrefix));
  if (options.json) {
    console.log(JSON.stringify({ reports: reports.length, dropped: droppedTotals(reports), histograms: merged }, null, 2));
    return;
  }
  printText(reports, merged, options);
}

await main();
