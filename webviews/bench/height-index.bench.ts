/// <reference types="bun" />

/**
 * Model-only deciding bench for transcript height corrections.
 *
 * This intentionally does not claim browser or React-frame coverage. It uses
 * the same row counts and token-burst update loop for the old full-prefix
 * placement shape and the immutable block-tree update path.
 *
 *   bun bench/height-index.bench.ts
 *   ROWS=9000 UPDATES=300 bun bench/height-index.bench.ts
 */
import { geometryFromHeights, placeMeasuredRows } from "../src/agent-session/acpmux/conversationGeometry";

const rows = Number(process.env.ROWS ?? 9_000);
const updates = Number(process.env.UPDATES ?? 300);
if (!Number.isSafeInteger(rows) || rows <= 0) throw new Error("ROWS must be a positive integer");
if (!Number.isSafeInteger(updates) || updates <= 0) throw new Error("UPDATES must be a positive integer");

const initial = new Float64Array(rows);
initial.fill(42);
const changed = Math.max(0, rows - 1);

function fullPrefixPlacement(values: Float64Array, nextHeight: number): number {
  const tops = new Float64Array(values.length);
  let top = 0;
  for (let index = 0; index < values.length; index += 1) {
    tops[index] = top;
    top += index === changed ? nextHeight : values[index]!;
  }
  return tops[changed]! + nextHeight;
}

const beforeStart = performance.now();
let beforeTotal = 0;
for (let update = 0; update < updates; update += 1) beforeTotal += fullPrefixPlacement(initial, 43 + (update & 1));
const beforeMs = performance.now() - beforeStart;

const estimate = geometryFromHeights(initial);
let index = estimate;
let heightReads = 0;
const afterStart = performance.now();
let afterTotal = 0;
for (let update = 0; update < updates; update += 1) {
  index = placeMeasuredRows(
    estimate,
    () => {
      heightReads += 1;
      return 43 + (update & 1);
    },
    [changed],
    { layout: index, from: rows },
  );
  afterTotal += index.totalHeight;
}
const afterMs = performance.now() - afterStart;

const report = {
  rows,
  updates,
  beforeMs: Number(beforeMs.toFixed(3)),
  afterMs: Number(afterMs.toFixed(3)),
  beforePerUpdateMs: Number((beforeMs / updates).toFixed(4)),
  afterPerUpdateMs: Number((afterMs / updates).toFixed(4)),
  speedup: Number((beforeMs / Math.max(afterMs, Number.EPSILON)).toFixed(2)),
  heightReads,
  totalsMatch: Math.abs(beforeTotal / updates - afterTotal / updates) < 0.001,
  scope: "model-only; no React, DOM, WebKit, or full-app frame claim",
};
if (!report.totalsMatch) throw new Error("full and indexed placement totals differ");
console.log(JSON.stringify(report, null, 2));
