/// <reference types="bun" />
// l10n-allow-file: bench output labels, not shipped UI.

/**
 * Model-only bench for the text every row formats with Intl: a chat's message ages, hover times and
 * date lines, turn footers' token counts, and Messages' list times. It calls the shipped functions
 * over ROWS rows, as one render of a long chat or list does, and prints µs per row (p50/p95 over
 * PASSES passes) for each.
 *
 * Before src/ui/intl.ts every one of these built a fresh Intl formatter per call; run this file on
 * the base commit and on the change, in one job on one machine, for the before/after:
 *
 *   bun bench/intl-formatters.bench.ts
 *   ROWS=2000 PASSES=50 bun bench/intl-formatters.bench.ts
 *
 * Bun runs JavaScriptCore, the engine of the macOS and iOS web views. No React, DOM or frame claim.
 */
import { exactTime, messageAge, replyTime } from "../src/agent-session/acpmux/conversation/relativeTime";
import { timestampText } from "../src/agent-session/acpmux/conversation/timestamps";
import { compactTokens } from "../src/agent-session/acpmux/conversation/turnTokensModel";
import { listTime } from "../src/pages/home-messages/list/model";

const rows = Number(process.env.ROWS ?? 1_000);
const passes = Number(process.env.PASSES ?? 40);
if (!Number.isSafeInteger(rows) || rows <= 0) throw new Error("ROWS must be a positive integer");
if (!Number.isSafeInteger(passes) || passes <= 0) throw new Error("PASSES must be a positive integer");

const now = Date.UTC(2026, 10, 21, 12, 0);
// Ages from a minute to two years, so every wording branch runs.
const ats = Array.from({ length: rows }, (_, index) => now - 60_000 * Math.floor(1.6 ** (index % 30)));
const locale = "en-US";

const workloads: Record<string, (at: number, index: number) => string> = {
  messageAge: (at) => messageAge(at, now, locale),
  exactTime: (at) => exactTime(at, locale),
  replyTime: (at) => replyTime(at, now, locale),
  timestampText: (at) => timestampText(at, { now, locale, timeZone: "America/Los_Angeles" }),
  compactTokens: (_, index) => compactTokens(locale, 1_234 * (index + 1)),
  listTime: (at) => listTime(at, now, locale, "Yesterday"),
};

function percentile(values: number[], share: number): number {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))]!;
}

let sink = 0;
const report: Record<string, unknown> = {
  rows,
  passes,
  engine: `bun ${Bun.version} (JavaScriptCore)`,
  scope: "model-only; no React, DOM or frame claim",
};
let total = 0;
for (const [name, run] of Object.entries(workloads)) {
  for (let index = 0; index < Math.min(rows, 200); index++) sink += run(ats[index]!, index).length; // warm up
  const perRow: number[] = [];
  for (let pass = 0; pass < passes; pass++) {
    const start = performance.now();
    for (let index = 0; index < rows; index++) sink += run(ats[index]!, index).length;
    perRow.push(((performance.now() - start) * 1_000) / rows);
  }
  const p50 = percentile(perRow, 0.5);
  total += p50;
  report[name] = { p50_us_per_row: +p50.toFixed(3), p95_us_per_row: +percentile(perRow, 0.95).toFixed(3) };
}
report.all_p50_us_per_row = +total.toFixed(3);
report.sink = sink > 0;
console.log(JSON.stringify(report, null, 2));
