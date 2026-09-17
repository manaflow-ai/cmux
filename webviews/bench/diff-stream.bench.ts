import { parsePatchFiles, processFile } from "@pierre/diffs";
import { resolve } from "node:path";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { JumpSelect } from "../src/App";
import { createDiffViewerLabelResolver } from "../src/labels";
import { streamPatch, type DiffItem, type StreamMetrics } from "../src/diff-stream";
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
const includeAppRender = process.env.CMUX_DIFF_BENCH_RENDER_APP === "1";
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
let lastAppMetrics: ReturnType<typeof createAppRenderMetrics> | null = null;
for (let index = 0; index < iterations; index += 1) {
  const appMetrics = createAppRenderMetrics();
  const started = performance.now();
  await streamPatch({
    getCollapsed: () => false,
    initialFileTreeRowCount: 32,
    label: createDiffViewerLabelResolver(undefined),
    onBatch: (batch) => {
      if (includeAppRender) {
        appMetrics.render(batch);
      }
    },
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
  if (includeAppRender && appMetrics.itemCount !== fileCount) {
    throw new Error(`app render received ${appMetrics.itemCount} files, expected ${fileCount}`);
  }
  if (includeAppRender && appMetrics.maxJumpOptionCount > 501) {
    throw new Error(`app render created ${appMetrics.maxJumpOptionCount} jump options, expected at most 501`);
  }
  lastAppMetrics = appMetrics;
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
  appRenderCount: includeAppRender ? lastAppMetrics?.renderCount ?? 0 : undefined,
  appRenderMs: includeAppRender ? Number((lastAppMetrics?.renderMs ?? 0).toFixed(2)) : undefined,
  appRenderedItemCount: includeAppRender ? lastAppMetrics?.itemCount ?? 0 : undefined,
  maxJumpOptionCount: includeAppRender ? lastAppMetrics?.maxJumpOptionCount ?? 0 : undefined,
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

function createAppRenderMetrics() {
  let items: DiffItem[] = [];
  let maxJumpOptionCount = 0;
  let renderCount = 0;
  let renderMs = 0;
  const label = createDiffViewerLabelResolver(undefined);
  return {
    get itemCount() {
      return items.length;
    },
    get maxJumpOptionCount() {
      return maxJumpOptionCount;
    },
    get renderCount() {
      return renderCount;
    },
    get renderMs() {
      return renderMs;
    },
    render(batch: DiffItem[]) {
      items = [...items, ...batch];
      const startedAt = performance.now();
      const markup = renderToStaticMarkup(createElement(JumpSelect, {
        items,
        label,
        onJump: () => {},
        onOpenSearch: () => {},
        searchOpen: false,
        selectedItemId: items[0]?.id ?? "",
      }));
      renderMs += performance.now() - startedAt;
      renderCount += 1;
      maxJumpOptionCount = Math.max(maxJumpOptionCount, markup.match(/<option(?:\s|>)/g)?.length ?? 0);
    },
  };
}
