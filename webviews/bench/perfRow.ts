// l10n-allow-file: benchmark output, not shipped UI.
// The machine-readable result line of a web UI bench, beside its own human output:
//   PERF_ROW {"name":"chat_open.latest","p50":412,"p95":431,"unit":"ms","target":1000}
// bench/web-ui-suite.ts collects these lines, and the perf cron (scripts/cmux-next/perf-cron.py, part
// "web-ui") stores each as the row webui.<name>, compares it with its last good values on the same runner
// class and puts a regression into the one "cmux-next perf regression" issue. Lower is better for every row.
//   name    dot-separated, stable across runs (a rename starts a new row). Never end it in .frame, .missed or
//           .dropped: the cron judges such rows by display refresh, which a headless Linux runner has none of.
//   p50/p95 ms (or `unit`). A bench that reports one median per round gives that median as both.
//   target  the value the row should stay under, when there is one; the suite and the cron list rows
//           slowest first relative to it. Targets follow one rule per kind of row (TARGET_MS).
//   floor   the change (in `unit`) that is noise on a shared runner; the cron's default is 10 % of p95.
//   version bump it when an edit changes what the row measures: the cron then rebases the row instead of
//           calling the change a regression (default 1).
export type PerfRow = {
  name: string;
  p50?: number;
  p95: number;
  unit?: string;
  target?: number;
  floor?: number;
  version?: number;
};

export const PERF_ROW_MARK = "PERF_ROW ";

/// One rule per kind of row, so a target is never a guess tuned to today's number.
export const TARGET_MS = {
  /// A click, key or switch until its result is painted: under 100 ms reads as instant.
  response: 100,
  /// A cold page load until the newest content is painted.
  load: 1000,
  /// Main-thread work in one animation frame (scroll, stream): what fits in a 60 Hz frame with room for paint.
  frameWork: 10,
} as const;

const round = (value: number) => Math.round(value * 1_000_000) / 1_000_000;

export function perfRow(row: PerfRow): void {
  if (!/^[a-z0-9_]+(\.[a-z0-9_-]+)*$/.test(row.name)) throw new Error(`perfRow: bad row name ${row.name}`);
  if (!Number.isFinite(row.p95)) throw new Error(`perfRow: ${row.name} has no p95`);
  const out: PerfRow = { ...row, p95: round(row.p95), unit: row.unit ?? "ms" };
  if (row.p50 !== undefined) out.p50 = round(row.p50);
  console.log(PERF_ROW_MARK + JSON.stringify(out));
}
