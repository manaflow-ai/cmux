// Lowers test/perf-budget-baseline.tsv, the perf budget hits each browser test file may have
// (test/support/perfBudgetGate.ts), from runs that wrote their counts:
//
//   CMUX_BROWSER_TESTS=1 CMUX_PERF_BUDGET_OBSERVED=$dir bun test ./test/<file>
//   bun scripts/perf-budget-baseline.ts --update $dir
//
// Each file with counts in $dir gets them as its rows. A count above its row is refused and nothing
// is written: the baseline only moves down. With no baseline file yet, the counts seed it.
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { formatBaseline, lowerBaseline, parseBaseline, rowFile } from "../test/support/perfBudgetBaseline";

const baselinePath =
  process.env.CMUX_PERF_BUDGET_BASELINE_FILE ??
  path.join(path.dirname(fileURLToPath(import.meta.url)), "../test/perf-budget-baseline.tsv");

/** Each observed file's counts, by test file: a file the run wrote with no rows had no hits. */
export function readObserved(dir: string): Map<string, Map<string, number>> {
  const observed = new Map<string, Map<string, number>>();
  for (const name of readdirSync(dir)
    .filter((entry) => entry.endsWith(".tsv"))
    .sort()) {
    const text = readFileSync(path.join(dir, name), "utf8");
    const file = /^# (.+)$/m.exec(text)?.[1];
    if (!file) throw new Error(`${name}: no "# <test file>" line`);
    const rows = parseBaseline(text);
    for (const key of rows.keys())
      if (rowFile(key) !== file) throw new Error(`${name}: a row of ${rowFile(key)} in ${file}'s counts`);
    observed.set(file, rows);
  }
  return observed;
}

if (import.meta.main) {
  const at = process.argv.indexOf("--update");
  const dir = at > 0 ? process.argv[at + 1] : undefined;
  if (!dir || !existsSync(dir)) {
    console.error("usage: bun scripts/perf-budget-baseline.ts --update <dir written by CMUX_PERF_BUDGET_OBSERVED>");
    process.exit(2);
  }
  const seed = !existsSync(baselinePath);
  const before = seed ? new Map<string, number>() : parseBaseline(readFileSync(baselinePath, "utf8"));
  const observed = readObserved(dir);
  const { rows, refused } = lowerBaseline(before, observed, { seed });
  if (refused.length > 0) {
    console.error("perf-budget-baseline: refusing to raise the baseline; fix the page instead:");
    for (const { key, count, baseline } of refused)
      console.error(`  ${key.replace(/\t/g, "  ")}: ${count} (baseline ${baseline})`);
    process.exit(1);
  }
  writeFileSync(baselinePath, formatBaseline(rows));
  const total = (map: Map<string, number>) => [...map.values()].reduce((sum, count) => sum + count, 0);
  console.log(
    `perf-budget-baseline: ${seed ? "seeded" : "written"} from ${observed.size} files: ${rows.size} rows, ${total(rows)} hits (was ${total(before)})`,
  );
}
