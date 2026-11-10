// l10n-allow-file: benchmark output, not shipped UI.
// Growth per operation of the pane's state layer, small and god side by side (bench/stateGrowth.ts): each scenario
// repeats one operation that should leave nothing behind and fits a line over full-GC samples after warm-up.
//   bun bench/state-growth.bench.ts [OPS] [--scale small|god|both] [--only a,b]
// Prints a table, then one PERF_ROW per scenario, scale and series (bytes, objects and entries per operation; the
// target is the slope's band), and exits 1 when a slope is over its band (rows in KNOWN excepted, until they pass).
// perf-cron.py's web-ui-growth part runs it.
/// <reference types="bun" />
import { PERF_ROW_MARK, type PerfRow } from "./perfRow";
import { SCENARIOS, type Growth } from "./stateGrowth";
import type { Scale } from "./godFixture";

const args = process.argv.slice(2);
const flag = (name: string) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const ops = Number(args.find((arg) => /^\d+$/.test(arg)) ?? 120);
const scaleArg = flag("--scale") ?? process.env.STRESS_SCALE ?? "both";
if (!["small", "god", "both"].includes(scaleArg)) {
  console.error(`state-growth: --scale ${scaleArg} is not small, god or both`);
  process.exit(2);
}
const scales: Scale[] = scaleArg === "both" ? ["small", "god"] : [scaleArg as Scale];
/// A scenario by the name it prints (session-churn) or its export (sessionChurn).
const printed = (name: string) => name.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
const only = flag("--only")?.split(",");
const named = (name: string) => Object.keys(SCENARIOS).some((key) => key === name || printed(key) === name);
const unknown = only?.filter((name) => !named(name));
if (unknown?.length) {
  const names = Object.keys(SCENARIOS).map(printed).join(", ");
  console.error(`state-growth: unknown scenario ${unknown.join(", ")} (one of ${names})`);
  process.exit(2);
}

/// Rows known to grow, each with its handoff: they still print and still fail their row on the cron, but the bench
/// exits 1 only for a failure not listed here or a listed one that passes (fixed: take it off this list).
const KNOWN: Record<string, string> = {
  "tool-output-stream/god": "manaflow-ai/cmuxterm-hq#8951",
  "reconnect-mid-stream/god": "manaflow-ai/cmuxterm-hq#8951",
};

const results: Growth[] = [];
for (const [name, run] of Object.entries(SCENARIOS)) {
  if (only && !only.includes(name) && !only.includes(printed(name))) continue;
  for (const scale of scales) {
    const growth = await run({ scale, ops });
    results.push(growth);
    console.log(
      `${growth.scenario.padEnd(22)} ${scale.padEnd(5)} ops ${String(growth.ops).padStart(4)}  ` +
        `heap ${growth.perOp.heapBytes.toFixed(0).padStart(9)} B/op  objects ${growth.perOp.objects.toFixed(1).padStart(8)}/op  ` +
        `entries ${growth.perOp.entries.toFixed(2).padStart(7)}/op  timers ${growth.perOp.timers.toFixed(2)}/op  ` +
        `${(growth.ms / 1000).toFixed(1)} s${growth.failures.length ? "  FAIL" : ""}`,
    );
    for (const failure of growth.failures) console.log(`  ${failure}`);
  }
}

/// A slope's row: its target is the band it is held to (noise, plus what streamed records weigh where a scenario
/// streams), so over target is what fails the bench; the band is its noise floor too.
const row = (name: string, value: number, unit: string, band: number): PerfRow => ({
  name,
  p50: Math.max(0, value),
  p95: Math.max(0, value),
  unit,
  target: Math.round(band * 100) / 100,
  floor: Math.round(band * 100) / 100,
  clock: "cpu",
});
for (const growth of results) {
  const base = `state_growth.${growth.scale === "god" ? "god." : ""}${growth.scenario.replaceAll("-", "_")}`;
  for (const each of [
    row(`${base}.heap_bytes_per_op`, growth.perOp.heapBytes, "bytes", growth.bands.heapBytes),
    row(`${base}.objects_per_op`, growth.perOp.objects, "objects", growth.bands.objects),
    row(`${base}.entries_per_op`, growth.perOp.entries, "entries", growth.bands.entries),
  ])
    console.log(PERF_ROW_MARK + JSON.stringify(each));
}
const verdicts = results.map((growth) => {
  const key = `${growth.scenario}/${growth.scale}`;
  const known = KNOWN[key];
  if (known && growth.failures.length) console.log(`state-growth: ${key} grows as known (${known})`);
  if (known && !growth.failures.length)
    console.log(`state-growth: ${key} passes: ${known} is fixed, take it off KNOWN`);
  return known ? growth.failures.length === 0 : growth.failures.length > 0;
});
process.exit(verdicts.some(Boolean) ? 1 : 0);
