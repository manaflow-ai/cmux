/// <reference types="bun" />
// l10n-allow-file: bench output labels, not shipped UI.

/**
 * Model-only bench for the transcript height estimate of sub-session cards (model.ts
 * `activityStepHeight` -> `replyHeight`): one estimate pass over ROWS finished replies and start
 * prompts, each an agent's multi-paragraph Markdown reply (~4 KB, ~60 lines). Prints ms per pass
 * (p50/p95 over PASSES). DURESS=1 is 10x the rows.
 *
 *   MODE=old bun bench/subsession-reply-height.bench.ts   (the old split of the whole reply)
 *   bun bench/subsession-reply-height.bench.ts            (the shipped count that stops at line four)
 *
 * Bun runs JavaScriptCore. No React, DOM or frame claim.
 */
import { replyHeight } from "../src/agent-session/acpmux/replyHeight";

const duress = !!process.env.DURESS;
const rows = Number(process.env.ROWS ?? (duress ? 20_000 : 2_000));
const passes = Number(process.env.PASSES ?? 40);
const mode = process.env.MODE ?? "new";

// The whole-reply count the shipped one replaced.
const bySplit = (reply: string) => {
  const lines = reply.split("\n").reduce((sum, line) => sum + Math.max(1, Math.ceil(line.length / 60)), 0);
  return Math.min(lines, 3) * 16 + (lines > 3 ? 20 : 0);
};
const height = mode === "old" ? bySplit : replyHeight;

const paragraph = (seed: number) =>
  `Checked ${seed} files under webviews/src; the estimate now reads the first lines only and the rest stays as it was.`;
const replies = Array.from({ length: rows }, (_, row) => {
  const lines: string[] = [`## Result ${row}`, ""];
  for (let at = 0; at < 30; at++) lines.push(at % 5 === 4 ? "" : `- ${paragraph(row + at)}`);
  lines.push("", "```ts", "const done = true;", "```");
  return lines.join("\n").repeat(1 + (row % 3));
});

const pass = () => {
  let total = 0;
  for (const reply of replies) total += height(reply);
  return total;
};
let sink = pass();
const times: number[] = [];
for (let p = 0; p < passes; p++) {
  const start = performance.now();
  sink += pass();
  times.push(performance.now() - start);
}
times.sort((a, b) => a - b);
console.log(
  JSON.stringify({
    bench: "subsession-reply-height",
    mode,
    rows,
    avgReplyChars: Math.round(replies.reduce((sum, reply) => sum + reply.length, 0) / rows),
    duress,
    passes,
    p50_ms: +times[times.length >> 1]!.toFixed(3),
    p95_ms: +times[Math.floor(times.length * 0.95)]!.toFixed(3),
    sink,
  }),
);
