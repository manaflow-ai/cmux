import { parsePatchFiles, processFile } from "@pierre/diffs";
import { createDiffViewerLabelResolver } from "../src/labels";
import { streamPatch, type StreamMetrics } from "../src/diff-stream";

const fileCount = Number(process.env.CMUX_DIFF_BENCH_FILES ?? 2000);
const iterations = Number(process.env.CMUX_DIFF_BENCH_ITERATIONS ?? 5);
const patch = makePatch(fileCount);
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
  flushCount: lastMetrics?.flushCount ?? 0,
  maxBatchSize: lastMetrics?.maxBatchSize ?? 0,
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
  return values[Math.floor(((values.length - 1) * target) / 100)] ?? 0;
}

function makePatch(count: number): string {
  let result = "";
  for (let index = 0; index < count; index += 1) {
    const path = `src/generated/file-${index}.ts`;
    result += [
      `diff --git a/${path} b/${path}`,
      "index 1111111..2222222 100644",
      `--- a/${path}`,
      `+++ b/${path}`,
      "@@ -1,3 +1,3 @@",
      ` export const id = ${index};`,
      "-export const state = \"old\";",
      "+export const state = \"new\";",
      " export const enabled = true;",
      "",
    ].join("\n");
  }
  return result;
}
