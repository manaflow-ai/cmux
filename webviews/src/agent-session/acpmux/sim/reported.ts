// Compare the distinct rows breaking each rule across replays of a captured chat.
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runSimulation } from "./run";
import { parseRecords } from "./sanitize";
import { replayScenario } from "./script";

type Counts = Record<string, number>;

/** A row breaking the same rule at many steps counts once. */
export function ruleCounts(violations: readonly { rule: string; rowId: string }[]): Counts {
  const rows = new Map<string, Set<string>>();
  for (const violation of violations) {
    const set = rows.get(violation.rule) ?? new Set<string>();
    set.add(violation.rowId);
    rows.set(violation.rule, set);
  }
  return Object.fromEntries([...rows].sort(([a], [b]) => a.localeCompare(b)).map(([rule, set]) => [rule, set.size]));
}

export function countChanges(expect: Counts, now: Counts) {
  return [...new Set([...Object.keys(expect), ...Object.keys(now)])]
    .sort()
    .map((rule) => ({ rule, before: expect[rule] ?? 0, after: now[rule] ?? 0 }))
    .filter((change) => change.before !== change.after);
}

/** Replay every fixture, returning true if any rule broke on more rows than recorded. */
export function replayReported(dir: string, update: boolean, log = console.log): boolean {
  let regressed = false;
  for (const file of readdirSync(dir)
    .filter((name) => name.endsWith(".ndjson"))
    .sort()) {
    const name = file.slice(0, -".ndjson".length);
    const sidecarPath = join(dir, `${name}.json`);
    const sidecar: { expect?: Counts } = existsSync(sidecarPath) ? JSON.parse(readFileSync(sidecarPath, "utf8")) : {};
    const started = performance.now();
    const records = parseRecords(readFileSync(join(dir, file), "utf8"));
    const result = runSimulation(replayScenario(name, records), { rowsInTraceUpTo: 0 });
    const now = ruleCounts(result.violations);
    const counts =
      Object.entries(now)
        .map(([rule, count]) => `${rule}=${count}`)
        .join(" ") || "no violations";
    const changes = sidecar.expect ? countChanges(sidecar.expect, now) : [];
    if (changes.some(({ before, after }) => after > before)) regressed = true;
    const summary = changes.length
      ? changes.map(({ rule, before, after }) => `${rule} ${before} -> ${after}`).join(", ")
      : `${sidecar.expect ? "same" : "no baseline"} (${counts})`;
    log(`${name}: ${summary} (${result.steps} steps, ${Math.round(performance.now() - started)} ms)`);
    if (update && (!sidecar.expect || changes.length))
      writeFileSync(sidecarPath, JSON.stringify({ ...sidecar, expect: now }, null, 2) + "\n");
  }
  return regressed;
}
