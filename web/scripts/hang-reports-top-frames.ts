/**
 * Top hang signatures from opt-in cmux NEXT hang reports. Read only.
 *
 *   DATABASE_URL=... bun scripts/hang-reports-top-frames.ts [--days 7] [--channel nightly]
 *     [--min-version 0.70.0] [--limit 20] [--json] [--symbolicate DSYM_DIR]
 *
 * Every query runs inside one `begin read only` transaction. Grouping rules
 * live in `scripts/hang-reports/topFrames.ts`. `--symbolicate` runs `atos`
 * on our frames, matching each frame's image UUID to a dSYM in DSYM_DIR by
 * `dwarfdump --uuid`.
 */
import { execFileSync } from "node:child_process";
import { readdirSync, statSync } from "node:fs";
import path from "node:path";
import postgres from "postgres";

import {
  atosArguments,
  compareVersions,
  frameLabel,
  groupHangs,
  mergeIntervals,
  mergeStallHistograms,
  parseDwarfdumpUuids,
  symbolicationRequests,
  type HangGroup,
  type StoredReport,
} from "./hang-reports/topFrames";

type Options = {
  readonly days: number;
  readonly channel: string | null;
  readonly minVersion: string | null;
  readonly limit: number;
  readonly json: boolean;
  readonly dsymDir: string | null;
};

function parseOptions(argv: readonly string[]): Options {
  const value = (flag: string): string | null => {
    const index = argv.indexOf(flag);
    if (index === -1) return null;
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) throw new Error(`${flag} needs a value`);
    return next;
  };
  const positive = (flag: string, fallback: number): number => {
    const raw = value(flag);
    if (raw === null) return fallback;
    if (!/^\d+$/.test(raw) || Number(raw) < 1) throw new Error(`${flag} must be a positive integer`);
    return Number(raw);
  };
  return {
    days: positive("--days", 7),
    channel: value("--channel"),
    minVersion: value("--min-version"),
    limit: positive("--limit", 20),
    json: argv.includes("--json"),
    dsymDir: value("--symbolicate"),
  };
}

async function loadReports(databaseURL: string, options: Options): Promise<StoredReport[]> {
  const sql = postgres(databaseURL, { max: 1 });
  try {
    const rows = await sql.begin("read only", (tx) => tx<{
      install_id: string;
      app_version: string | null;
      app_build: string | null;
      channel: string | null;
      payload: StoredReport["payload"];
    }[]>`
      select install_id, app_version, app_build, channel, payload
      from hang_reports
      where received_at >= now() - make_interval(days => ${options.days})
        ${options.channel ? tx`and channel = ${options.channel}` : tx``}
    `);
    return rows
      .filter((row) => !options.minVersion || (row.app_version !== null && compareVersions(row.app_version, options.minVersion) >= 0))
      .map((row) => ({
        installId: row.install_id,
        appVersion: row.app_version,
        appBuild: row.app_build,
        channel: row.channel,
        payload: row.payload,
      }));
  } finally {
    await sql.end();
  }
}

function dsymBinaries(directory: string): string[] {
  const found: string[] = [];
  const walk = (current: string): void => {
    for (const entry of readdirSync(current)) {
      const full = path.join(current, entry);
      if (!statSync(full).isDirectory()) continue;
      if (entry.endsWith(".dSYM")) {
        const dwarf = path.join(full, "Contents", "Resources", "DWARF");
        for (const binary of readdirSync(dwarf)) found.push(path.join(dwarf, binary));
      } else {
        walk(full);
      }
    }
  };
  walk(directory);
  return found;
}

/** Symbol text keyed by `UUID:offset`, for our frames that a dSYM in `directory` covers. */
function symbolicate(groups: readonly HangGroup[], directory: string): Map<string, string> {
  const binaries = new Map<string, { readonly arch: string; readonly path: string }>();
  for (const binary of dsymBinaries(directory)) {
    const output = execFileSync("dwarfdump", ["--uuid", binary], { encoding: "utf8" });
    for (const [uuid, entry] of parseDwarfdumpUuids(output)) binaries.set(uuid, entry);
  }
  const symbols = new Map<string, string>();
  for (const [uuid, offsets] of symbolicationRequests(groups)) {
    const binary = binaries.get(uuid);
    if (!binary) continue;
    const output = execFileSync("atos", atosArguments(binary.path, binary.arch, offsets), { encoding: "utf8" });
    output.trimEnd().split("\n").forEach((line, index) => {
      const offset = offsets[index];
      if (offset !== undefined) symbols.set(`${uuid}:${offset}`, line.trim());
    });
  }
  return symbols;
}

function frameText(frame: HangGroup["frames"][number], symbols: Map<string, string>): string {
  const symbol = frame.uuid != null && frame.offset != null
    ? symbols.get(`${frame.uuid.toUpperCase()}:${frame.offset}`)
    : undefined;
  return symbol ? `${frameLabel(frame)}  ${symbol}` : frameLabel(frame);
}

function counts(record: Readonly<Record<string, number>>): string {
  return Object.entries(record).sort((a, b) => b[1] - a[1]).map(([key, value]) => `${key}=${value}`).join(" ");
}

function printText(reports: readonly StoredReport[], groups: readonly HangGroup[], symbols: Map<string, string>, options: Options): void {
  const installs = new Set(reports.map((report) => report.installId)).size;
  console.log(`${reports.length} reports from ${installs} installs, last ${options.days} days`);
  console.log("");
  groups.slice(0, options.limit).forEach((group, index) => {
    const durations = group.p50DurationMs === null
      ? "no MetricKit durations"
      : `MetricKit p50 ${group.p50DurationMs} ms, p95 ${group.p95DurationMs} ms (n=${group.metrickitHangs})`;
    console.log(`#${index + 1}  ${group.installs} installs, ${group.count} hangs, ${durations}, watchdog >=2s ${group.watchdogHangs}`);
    console.log(`    kinds: ${counts(group.kinds)}   sources: ${counts(group.sources)}`);
    console.log(`    builds: ${counts(group.appBuilds)}`);
    for (const frame of group.frames) console.log(`      ${frameText(frame, symbols)}`);
    console.log("");
  });
  const stalls = mergeStallHistograms(reports);
  console.log(`Stall histogram (sum ${stalls.reduce((total, bucket) => total + bucket.count, 0)})`);
  for (const bucket of stalls) console.log(`  ${bucket.lowMs}-${bucket.highMs} ms: ${bucket.count}`);
  console.log("");
  console.log("Intervals");
  for (const interval of mergeIntervals(reports)) {
    const hitch = interval.hitchMsPerS === null ? "n/a" : interval.hitchMsPerS.toFixed(2);
    console.log(`  ${interval.category} ${interval.name}: ${interval.count} intervals, hitch ${hitch} ms/s`);
    for (const bucket of interval.buckets) console.log(`    ${bucket.lowMs}-${bucket.highMs} ms: ${bucket.count}`);
  }
}

async function main(): Promise<void> {
  const options = parseOptions(process.argv.slice(2));
  const databaseURL = process.env.DATABASE_URL?.trim();
  if (!databaseURL) throw new Error("DATABASE_URL is required");
  const reports = await loadReports(databaseURL, options);
  const groups = groupHangs(reports);
  const symbols = options.dsymDir ? symbolicate(groups.slice(0, options.limit), options.dsymDir) : new Map<string, string>();
  if (options.json) {
    console.log(JSON.stringify({
      reports: reports.length,
      installs: new Set(reports.map((report) => report.installId)).size,
      groups: groups.slice(0, options.limit).map((group) => ({
        ...group,
        frames: group.frames.map((frame) => ({ ...frame, label: frameText(frame, symbols) })),
      })),
      stallHistogram: mergeStallHistograms(reports),
      intervals: mergeIntervals(reports),
    }, null, 2));
    return;
  }
  printText(reports, groups, symbols, options);
}

await main();
