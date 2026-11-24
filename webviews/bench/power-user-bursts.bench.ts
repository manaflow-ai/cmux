// l10n-allow-file: benchmark output, not shipped UI.
// The power-user input stress harness's long-seed run for the perf cron (scripts/cmux-next/perf-cron.py, part
// web-ui-power-user): test/power-user-bursts.browser.test.ts with a fresh random seed and many waves, report-only, its
// numbers per input class and engine as PERF_ROW lines (webui.power_user.<kind>.<engine>.<metric>), and its breaches,
// each with the seed that replays it, as POWER-USER-BREACH lines.
//   bun bench/power-user-bursts.bench.ts [--waves 150] [--seed N|random] [--engines chromium,webkit]
// Leo, 2026-11-22: "we need to test like power users more often."
/// <reference types="bun" />
import path from "node:path";
import { perfRow } from "./perfRow";

const flag = (name: string) => {
  const at = process.argv.indexOf(name);
  return at >= 0 ? process.argv[at + 1] : undefined;
};
const waves = flag("--waves") ?? "150";
const seed = flag("--seed") ?? "random";
const engines = flag("--engines") ?? "chromium,webkit";

const webviews = path.resolve(import.meta.dir, "..");
const proc = Bun.spawn(["bun", "test", "test/power-user-bursts.browser.test.ts"], {
  cwd: webviews,
  env: {
    ...process.env,
    CMUX_BROWSER_TESTS: "1",
    POWER_USER_SEED: seed,
    POWER_USER_WAVES: waves,
    POWER_USER_ENGINES: engines,
    POWER_USER_REPORT_ONLY: "1",
    POWER_USER_BUDGET_S: "600",
  },
  stdout: "pipe",
  stderr: "pipe",
  stdin: "ignore",
});
const [stdout, stderr, exit] = await Promise.all([
  new Response(proc.stdout).text(),
  new Response(proc.stderr).text(),
  proc.exited,
]);
const lines = `${stdout}\n${stderr}`.split("\n").filter((line) => line.startsWith("POWER-USER "));
if (lines.length === 0) {
  console.log(`${stdout}\n${stderr}`.split("\n").slice(-40).join("\n"));
  console.log(`power-user-bursts: the harness printed no report (exit ${exit})`);
  process.exit(1);
}
type Numbers = Record<string, Record<string, number | boolean>>;
for (const line of lines) {
  const report = JSON.parse(line.slice("POWER-USER ".length)) as {
    engine: string;
    seed: number;
    numbers: Numbers;
    breaches: { kind: string; what: string; value: unknown; budget: unknown }[];
    replay: string;
  };
  console.log(`power-user-bursts: ${report.engine} seed ${report.seed}: ${report.breaches.length} breach(es)`);
  for (const breach of report.breaches)
    console.log(`POWER-USER-BREACH ${JSON.stringify({ ...breach, replay: report.replay })}`);
  for (const [kind, numbers] of Object.entries(report.numbers)) {
    const base = `power_user.${kind}.${report.engine}`;
    perfRow({ name: `${base}.frame_p95`, p95: numbers.frame_p95_ms as number, target: 33.4 });
    perfRow({ name: `${base}.frame_p99`, p95: numbers.frame_p99_ms as number, target: 66.8 });
    perfRow({ name: `${base}.input_to_paint`, p95: numbers.input_to_paint_p95_ms as number, target: 50 });
    perfRow({ name: `${base}.long_frames`, p95: numbers.long_frames as number, unit: "count", target: 0 });
    perfRow({ name: `${base}.stray_px`, p95: numbers.stray_worst_px as number, unit: "px", target: 1 });
    perfRow({ name: `${base}.blank_frames`, p95: numbers.blank_frames as number, unit: "count", target: 0 });
    if (typeof numbers.caret_lag_p95_ms === "number") {
      perfRow({ name: `${base}.caret_lag`, p95: numbers.caret_lag_p95_ms, target: 50 });
      perfRow({ name: `${base}.dropped_keys`, p95: numbers.dropped_keys as number, unit: "count", target: 0 });
    }
  }
}
