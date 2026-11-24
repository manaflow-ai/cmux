/// <reference types="bun" />
// l10n-allow-file: bench output labels, not shipped UI.

/**
 * Model-only bench for transcript placement: base's sequential `placeRows` (before) against the
 * gap-aware index's `placeRowsIndexed` (after), fed the same estimate, marks and drawn heights as
 * App.tsx feeds them, for the three passes a long chat makes:
 *
 * - token: the last row (a streaming reply) grows; every row before it is kept;
 * - middle: a row half way down draws at a new height (a fold, an image loading);
 * - top: a row near the top draws at a new height (a measure after scrolling to the top).
 *
 * Each pass places from the previous one, as App does. It checks that both give the same total and
 * tops, and prints ms per pass (p50/p95) for each. No React, DOM or browser frame claim.
 *
 *   bun bench/height-index.bench.ts
 *   ROWS=9000 PASSES=300 bun bench/height-index.bench.ts
 */
import {
  placeRows,
  placeRowsIndexed,
  type ConversationLayout,
  type PlacedLayout,
} from "../src/agent-session/acpmux/model";
import { MARK_MESSAGE, MARK_PROMPT, MARK_STEP, MARK_FOOTER_ROW } from "../src/agent-session/acpmux/transcriptGrid";

const rows = Number(process.env.ROWS ?? 9_000);
const passes = Number(process.env.PASSES ?? 300);
if (!Number.isSafeInteger(rows) || rows <= 1) throw new Error("ROWS must be an integer above 1");
if (!Number.isSafeInteger(passes) || passes <= 0) throw new Error("PASSES must be a positive integer");

// A chat's shape: prompt, steps, a reply, its footer row, and rows that draw nothing.
const MARK_CYCLE = [MARK_PROMPT, MARK_STEP, MARK_STEP, 0, MARK_MESSAGE, MARK_FOOTER_ROW, 0];
const estimate: ConversationLayout = {
  tops: new Float64Array(rows),
  heights: Float64Array.from({ length: rows }, (_, index) => (index % 7 === 3 ? 0 : 22.75 + (index % 13) * 8)),
  marks: Uint8Array.from({ length: rows }, (_, index) => MARK_CYCLE[index % MARK_CYCLE.length]!),
  totalHeight: 0,
  scale: 1,
};
const drawn = Float64Array.from(estimate.heights);
const heightAt = (index: number) => drawn[index];

function percentile(values: number[], share: number): number {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))]!;
}

type Workload = { name: string; row: number };
const workloads: Workload[] = [
  { name: "token", row: rows - 1 },
  { name: "middle", row: Math.floor(rows / 2) },
  { name: "top", row: 5 },
];

const report: Record<string, unknown> = { rows, passes, scope: "model-only; no React, DOM, WebKit or frame claim" };
for (const { name, row } of workloads) {
  drawn.set(estimate.heights);
  let before = placeRows(estimate, heightAt);
  let after: PlacedLayout = placeRowsIndexed(estimate, heightAt);
  const beforeMs: number[] = [];
  const afterMs: number[] = [];
  for (let pass = 0; pass < passes; pass += 1) {
    drawn[row] = estimate.heights[row]! + 1 + (pass % 5);
    let start = performance.now();
    before = placeRows(estimate, heightAt, { layout: before, kept: row });
    beforeMs.push(performance.now() - start);
    start = performance.now();
    after = placeRowsIndexed(estimate, heightAt, {
      layout: after,
      kept: row,
      from: rows,
      changed: [row],
    });
    afterMs.push(performance.now() - start);
  }
  for (const at of [0, row, rows - 1])
    if (Math.abs(after.geometry.topAt(at) - before.tops[at]!) > 1e-6) throw new Error(`${name}: tops differ at ${at}`);
  if (Math.abs(after.totalHeight - before.totalHeight) > 1e-6) throw new Error(`${name}: totals differ`);
  const sum = (values: number[]) => values.reduce((total, value) => total + value, 0);
  report[name] = {
    beforeP50Ms: Number(percentile(beforeMs, 0.5).toFixed(4)),
    beforeP95Ms: Number(percentile(beforeMs, 0.95).toFixed(4)),
    afterP50Ms: Number(percentile(afterMs, 0.5).toFixed(4)),
    afterP95Ms: Number(percentile(afterMs, 0.95).toFixed(4)),
    speedupTotal: Number((sum(beforeMs) / Math.max(sum(afterMs), Number.EPSILON)).toFixed(2)),
  };
}
console.log(JSON.stringify(report, null, 2));
