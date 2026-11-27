// l10n-allow-file: benchmark output, not shipped UI.
// Growth per operation: an operation that leaves the pane where it started (switch to a chat and back, open and
// close) must leave nothing behind. A bench repeats it many times on one page and samples, after a forced GC, the JS
// heap, the DOM nodes and the event listeners (CDP Memory.getDOMCounters); the least-squares slope of each over the
// operation count is what the operation leaks. The rows target 0: any slope above its resolution is a leak, and the
// perf cron lists it. Repeating the operation fast on a fake clock replaces a soak: 40 switches show a leak an hour of
// use would.
/// <reference types="bun" />
import type { CDPSession } from "playwright";
import type { PerfRow } from "./perfRow";
import { slope } from "./replayLogs";

export type GrowthSample = { op: number; heapKb: number; nodes: number; listeners: number };
export type Growth = { heapKbPerOp: number; nodesPerOp: number; listenersPerOp: number };

/// What one sample can tell apart from noise, per operation: a GC'd heap moves a few KB between samples, a node or
/// listener count does not move at all when nothing leaks. A slope at or under its resolution reports 0.
export const RESOLUTION: Growth = { heapKbPerOp: 4, nodesPerOp: 0.5, listenersPerOp: 0.25 };

/// The slope of each counter over the operations (pure), with anything at or under RESOLUTION reported as 0 and
/// a falling counter (a cache warming down) as 0 too: only growth counts.
export function growthPerOp(samples: readonly GrowthSample[]): Growth {
  if (samples.length < 3) throw new Error(`growth needs 3 samples or more, got ${samples.length}`);
  const of = (pick: (sample: GrowthSample) => number, resolution: number) => {
    const value = slope(samples.map((sample) => ({ x: sample.op, y: pick(sample) })));
    return value > resolution ? Math.round(value * 100) / 100 : 0;
  };
  return {
    heapKbPerOp: of((s) => s.heapKb, RESOLUTION.heapKbPerOp),
    nodesPerOp: of((s) => s.nodes, RESOLUTION.nodesPerOp),
    listenersPerOp: of((s) => s.listeners, RESOLUTION.listenersPerOp),
  };
}

/// One sample of a Chromium page after a forced GC.
export async function sampleGrowth(cdp: CDPSession, op: number): Promise<GrowthSample> {
  await cdp.send("HeapProfiler.collectGarbage");
  const heap = (await cdp.send("Runtime.getHeapUsage")) as { usedSize: number };
  const dom = (await cdp.send("Memory.getDOMCounters")) as { nodes: number; jsEventListeners: number };
  return { op, heapKb: heap.usedSize / 1024, nodes: dom.nodes, listeners: dom.jsEventListeners };
}

/// The three rows of an operation's growth, `<prefix>.heap_kb_per_<op>` and so on, each with target 0.
export function growthRows(prefix: string, op: string, growth: Growth): PerfRow[] {
  const row = (metric: string, value: number, unit: string, floor: number): PerfRow => ({
    name: `${prefix}.${metric}_per_${op}`,
    p50: value,
    p95: value,
    unit,
    target: 0,
    floor,
    clock: "cpu",
  });
  return [
    row("heap_kb", growth.heapKbPerOp, "KB", RESOLUTION.heapKbPerOp),
    row("dom_nodes", growth.nodesPerOp, "count", RESOLUTION.nodesPerOp),
    row("listeners", growth.listenersPerOp, "count", RESOLUTION.listenersPerOp),
  ];
}
