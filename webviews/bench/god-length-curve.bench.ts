// l10n-allow-file: benchmark output, not shipped UI.
// The god chat's length curve. It checks that what a streamed update costs, and what the chat holds, does not grow with
// the transcript. Replay cost should follow what is on screen, not the transcript's length. A chat holds the newest
// page it opened on plus a bounded live window (src/agent-session/acpmux/direct/heldRecords.ts `HELD_RECORDS`),
// reads older pages only when scrolled to (`loadOlder`), and keeps the rail's prompts as columns (promptHeads.ts).
// This bench measures that claim at three lengths.
// It plays the god session (bench/godFixture.ts) through transcript-replay.bench.ts at TURNS_LIST turns (default
// 1000,10000,100000), one replay each, on one machine. From each replay it reads the per-update rows and the heap row
// that NOW's god_chat_replay_ratio_max reads: transcript_replay.god.long.{token_ms,thought_ms,heap_mb}, at p95.
// Rows (PERF_ROW):
//   god_length_curve.<metric>.t<turns>  each replay's value
//   god_length_curve.<metric>.ratio     the longest replay's value over the shortest's
//   god_length_curve.ratio_max          the worst of those ratios. The curve is flat when this is <= 1.2 (TARGET):
//                                       100x the history costs at most 1.2x per update and in heap.
// Leo's direction (shadow-leo, 2026-11-28): "the check turns into a curve, heap and tokens at 1k, 10k, 100k turns,
// and it has to stay flat".
//   bun bench/god-length-curve.bench.ts            (CLOCK=cpu and the bench's other env pass through)
//   TURNS_LIST=1000,10000 bun bench/god-length-curve.bench.ts
/// <reference types="bun" />
import path from "node:path";
import { PERF_ROW_MARK, perfRow } from "./perfRow";

const TARGET = 1.2;
const METRICS = ["token_ms", "thought_ms", "heap_mb"] as const;
type Metric = (typeof METRICS)[number];

/// The god rows of one replay's output (pure; exported for the test).
export function godRows(output: string): Partial<Record<Metric, number>> {
  const found: Partial<Record<Metric, number>> = {};
  for (const line of output.split("\n")) {
    const at = line.indexOf(PERF_ROW_MARK);
    if (at < 0) continue;
    let row: { name?: string; p95?: number };
    try {
      row = JSON.parse(line.slice(at + PERF_ROW_MARK.length));
    } catch {
      continue;
    }
    for (const metric of METRICS)
      if (row.name === `transcript_replay.god.long.${metric}` && typeof row.p95 === "number") found[metric] = row.p95;
  }
  return found;
}

/// Each metric's ratio of its longest replay to its shortest, and the worst ratio (pure; exported for the test).
export function curveRatios(points: { turns: number; rows: Partial<Record<Metric, number>> }[]): {
  ratios: Partial<Record<Metric, number>>;
  max: number;
} {
  const sorted = [...points].sort((a, b) => a.turns - b.turns);
  const ratios: Partial<Record<Metric, number>> = {};
  let max = 0;
  for (const metric of METRICS) {
    const first = sorted[0]?.rows[metric];
    const last = sorted.at(-1)?.rows[metric];
    if (first === undefined || last === undefined || first <= 0 || sorted.length < 2) continue;
    ratios[metric] = last / first;
    max = Math.max(max, last / first);
  }
  return { ratios, max };
}

if (import.meta.main) {
  const turnsList = (process.env.TURNS_LIST ?? "1000,10000,100000").split(",").map(Number);
  if (turnsList.length < 2 || turnsList.some((turns) => !Number.isInteger(turns) || turns < 10)) {
    console.error("god-length-curve: TURNS_LIST is two or more whole turn counts, each 10 or more");
    process.exit(2);
  }
  const bench = path.join(import.meta.dir, "transcript-replay.bench.ts");
  const points: { turns: number; rows: Partial<Record<Metric, number>> }[] = [];
  for (const turns of turnsList) {
    const started = performance.now();
    const proc = Bun.spawn(["bun", bench, "--only", "long"], {
      env: { TAIL: "1", ...process.env, FIXTURE: "god", GOD_TURNS: String(turns) },
      stdout: "pipe",
      stderr: "inherit",
    });
    const output = await new Response(proc.stdout).text();
    const code = await proc.exited;
    const rows = godRows(output);
    const seconds = ((performance.now() - started) / 1000).toFixed(0);
    console.log(`god-length-curve: ${turns} turns: exit ${code} in ${seconds} s: ${JSON.stringify(rows)}`);
    if (code !== 0 || METRICS.some((metric) => rows[metric] === undefined)) {
      console.error(output.split("\n").slice(-40).join("\n"));
      console.error(`god-length-curve: the ${turns}-turn replay gave no full set of rows`);
      process.exit(1);
    }
    points.push({ turns, rows });
    for (const metric of METRICS) {
      const value = rows[metric]!;
      perfRow({
        name: `god_length_curve.${metric}.t${turns}`,
        p50: value,
        p95: value,
        unit: metric === "heap_mb" ? "MB" : "ms",
        ...(process.env.CLOCK === "cpu" && metric !== "heap_mb" ? { clock: "cpu" as const } : {}),
      });
    }
  }
  const { ratios, max } = curveRatios(points);
  for (const metric of METRICS)
    if (ratios[metric] !== undefined)
      perfRow({
        name: `god_length_curve.${metric}.ratio`,
        p50: ratios[metric],
        p95: ratios[metric]!,
        unit: "x",
        target: TARGET,
      });
  perfRow({ name: "god_length_curve.ratio_max", p50: max, p95: max, unit: "x", target: TARGET });
  const first = turnsList[0];
  const last = turnsList.at(-1);
  console.log(
    `god-length-curve: ${last} turns over ${first}: ${METRICS.map((m) => `${m} ${ratios[m]?.toFixed(3)}x`).join(", ")}; ` +
      `max ${max.toFixed(3)}x (${max <= TARGET ? "flat" : "NOT FLAT"}, target <= ${TARGET}x)`,
  );
}
