import { parsePatchFiles, processFile } from "@pierre/diffs";
import { resolve } from "node:path";
import { createDiffViewerLabelResolver } from "../src/labels";
import { streamPatch, type StreamMetrics } from "../src/diff-stream";
import { makeMixedPatch } from "./diff-fixture";

const fileCount = Number(process.env.CMUX_DIFF_BENCH_FILES ?? 2000);
const iterations = Number(process.env.CMUX_DIFF_BENCH_ITERATIONS ?? 5);
if (!Number.isSafeInteger(fileCount) || fileCount <= 0) {
  throw new Error("CMUX_DIFF_BENCH_FILES must be a positive integer");
}
if (!Number.isSafeInteger(iterations) || iterations <= 0) {
  throw new Error("CMUX_DIFF_BENCH_ITERATIONS must be a positive integer");
}
const patch = makeMixedPatch(fileCount);
const patchOutputPath = process.env.CMUX_DIFF_BENCH_PATCH_OUTPUT == null
  ? undefined
  : resolve(process.env.CMUX_DIFF_BENCH_PATCH_OUTPUT);
if (patchOutputPath != null) {
  await Bun.write(patchOutputPath, patch);
}
const originalFetch = globalThis.fetch;
const originalDocument = globalThis.document;
const originalWindow = globalThis.window;

Object.assign(globalThis, {
  document: { visibilityState: "hidden", hasFocus: () => false },
  window: globalThis,
  fetch: async () => new Response(patch, {
    status: 200,
    headers: { "Content-Type": "text/x-diff" },
  }),
});

const samples: number[] = [];
let lastMetrics: StreamMetrics | null = null;
for (let index = 0; index < iterations; index += 1) {
  const started = performance.now();
  await streamPatch({
    getCollapsed: () => false,
    initialFileTreeRowCount: 32,
    label: createDiffViewerLabelResolver(undefined),
    onBatch: () => {},
    onComplete: (metrics) => {
      lastMetrics = metrics;
    },
    onMetrics: () => {},
    onRename: () => {},
    onTreeSource: () => {},
    parsePatchFiles,
    patchURL: "benchmark.patch",
    processFile,
  });
  samples.push(performance.now() - started);
}

globalThis.fetch = originalFetch;
globalThis.document = originalDocument;
globalThis.window = originalWindow;

samples.sort((left, right) => left - right);
const medianMs = percentile(samples, 50);
const p95Ms = percentile(samples, 95);
const report = {
  patchBytes: new TextEncoder().encode(patch).byteLength,
  fileCount,
  iterations,
  medianMs: Number(medianMs.toFixed(2)),
  p95Ms: Number(p95Ms.toFixed(2)),
  filesPerSecond: Math.round(fileCount / (medianMs / 1000)),
  firstBatchFileCount: lastMetrics?.firstBatchFileCount ?? 0,
  firstBatchMs: lastMetrics?.firstBatchAt == null
    ? null
    : Number((lastMetrics.firstBatchAt - lastMetrics.startedAt).toFixed(2)),
  flushCount: lastMetrics?.flushCount ?? 0,
  longYieldCount: lastMetrics?.longYieldCount ?? 0,
  maxBatchSize: lastMetrics?.maxBatchSize ?? 0,
  maxYieldMs: Number((lastMetrics?.maxYieldMs ?? 0).toFixed(2)),
  patchOutputPath,
  yieldCount: lastMetrics?.yieldCount ?? 0,
};
const maxP95Ms = Number(process.env.CMUX_DIFF_BENCH_MAX_STREAM_P95_MS ?? Number.POSITIVE_INFINITY);
if (!Number.isFinite(maxP95Ms) && maxP95Ms !== Number.POSITIVE_INFINITY) {
  throw new Error("CMUX_DIFF_BENCH_MAX_STREAM_P95_MS must be a number");
}
if (p95Ms > maxP95Ms) {
  throw new Error(`diff stream p95 was ${p95Ms.toFixed(2)} ms, budget is ${maxP95Ms.toFixed(2)} ms`);
}
await Bun.write(Bun.stdout, `${JSON.stringify(report, null, 2)}\n`);
process.exit(0);

function percentile(values: number[], target: number): number {
  const rank = Math.ceil((values.length * target) / 100);
  return values[Math.max(0, Math.min(values.length - 1, rank - 1))] ?? 0;
}
