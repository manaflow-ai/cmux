/// <reference types="bun" />
// l10n-allow-file: bench output labels, not shipped UI.

/**
 * Model-only bench for the turn-end fold's curve search (`turnEndFoldTiming`), the call a fold's
 * placement pass makes when it finds a longer move. For each move it times a cold call (a fresh
 * module, so no memo) and a repeated call, over many iterations, and prints median and p99 ms and
 * the result. No React, DOM or browser frame claim.
 *
 *   bun bench/turn-end-fold-timing.bench.ts
 *   COLD=200 WARM=5000 bun bench/turn-end-fold-timing.bench.ts
 */
import { MOTION_SETTLE, MOTION_SETTLE_MS } from "../src/motion/scale.generated";

const cold = Number(process.env.COLD ?? 200);
const warm = Number(process.env.WARM ?? 5_000);
if (!Number.isSafeInteger(cold) || cold <= 0) throw new Error("COLD must be a positive integer");
if (!Number.isSafeInteger(warm) || warm <= 0) throw new Error("WARM must be a positive integer");
const moves = [45, 274, 800, 2000];
const modulePath = "../src/agent-session/acpmux/conversation/turnEndFold";

type Timing = (px: number, ms: number, easing: string) => { ms: number; easing: string };
type Module = { turnEndFoldTiming: Timing; clearTurnEndFoldMemo?: () => void };

function percentile(values: number[], share: number): number {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))]!;
}
const round = (value: number) => Math.round(value * 10_000) / 10_000;

const fold = (await import(modulePath)) as Module;
// Cold: no memo. The memo's clear when the module has one; base has none, so every call is cold there.
const coldCall = (px: number) => {
  fold.clearTurnEndFoldMemo?.();
  const start = performance.now();
  const result = fold.turnEndFoldTiming(px, MOTION_SETTLE_MS, MOTION_SETTLE);
  return { ms: performance.now() - start, result };
};

const report: Record<string, unknown>[] = [];
for (const px of moves) {
  // Warm the JIT on this move first.
  for (let index = 0; index < 5; index += 1) coldCall(px);
  const colds: number[] = [];
  let result: { ms: number; easing: string } | undefined;
  for (let index = 0; index < cold; index += 1) {
    const run = coldCall(px);
    colds.push(run.ms);
    result = run.result;
  }
  fold.turnEndFoldTiming(px, MOTION_SETTLE_MS, MOTION_SETTLE);
  const warms: number[] = [];
  for (let index = 0; index < warm; index += 1) {
    const start = performance.now();
    fold.turnEndFoldTiming(px, MOTION_SETTLE_MS, MOTION_SETTLE);
    warms.push(performance.now() - start);
  }
  report.push({
    px,
    coldMedianMs: round(percentile(colds, 0.5)),
    coldP99Ms: round(percentile(colds, 0.99)),
    repeatMedianMs: round(percentile(warms, 0.5)),
    repeatP99Ms: round(percentile(warms, 0.99)),
    result,
  });
}
console.log(JSON.stringify({ cold, warm, scope: "model-only; no React, DOM, WebKit or frame claim", report }, null, 2));
