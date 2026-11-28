/// <reference types="bun" />
// l10n-allow-file: bench output labels, not shipped UI.

/**
 * Model-only bench for `inlineText` on text with no marks (the common question/option text): the
 * `hasMarks` test used to construct a RegExp per call. Prints µs per call (p50/p95 over PASSES).
 * Duress: DURESS=1 uses long (4 KB) texts as a long chat fixture's prose does.
 *
 *   bun bench/inline-text-hasmarks.bench.ts
 *   DURESS=1 bun bench/inline-text-hasmarks.bench.ts
 *
 * Bun runs JavaScriptCore. No React, DOM or frame claim.
 */
import { inlineText } from "../src/agent-session/acpmux/question/inlineText";

const rows = Number(process.env.ROWS ?? 2_000);
const passes = Number(process.env.PASSES ?? 40);
const word = process.env.DURESS
  ? "plain words without any marks at all, ".repeat(100)
  : "Which option should we pick for ";
const texts = Array.from({ length: rows }, (_, i) => `${word}${i} (2 * 3 = 6, snake_case_name)`);
let sink = 0;
for (const t of texts) sink += (inlineText(t) as string).length; // warm
const times: number[] = [];
for (let p = 0; p < passes; p++) {
  const start = performance.now();
  for (const t of texts) sink += (inlineText(t) as string).length;
  times.push(((performance.now() - start) * 1000) / rows);
}
times.sort((a, b) => a - b);
console.log(
  JSON.stringify({
    bench: "inline-text-hasmarks",
    rows,
    passes,
    duress: !!process.env.DURESS,
    p50_us: +times[Math.floor(times.length / 2)]!.toFixed(3),
    p95_us: +times[Math.floor(times.length * 0.95)]!.toFixed(3),
    sink,
  }),
);
