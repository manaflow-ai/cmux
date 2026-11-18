// The browser test gate's baseline (support/perfBudgetGate.ts): which perf budget classes fail a test
// file, the stable name of each hit, and the rows of test/perf-budget-baseline.tsv that only shrink.
// No Node or Playwright imports: the page script (perfBudgetGate.entry.ts) and the update script
// (scripts/perf-budget-baseline.ts) share it.
import type { PerfBudgetClass } from "../../src/devkit/perfBudgets";

/**
 * The classes that fail a test file. They count things the page did (element children of one
 * element, live setInterval handles), so a page measures the same on a loaded CI runner as on a
 * quiet laptop. The others time things (a frame's length, a commit's render time, a shift seen
 * between two frames, redraws per wall-clock second): on a runner busy with other browsers they
 * fire on pages that are fine, so they stay warnings under `cmux live`.
 */
export const GATED_CLASSES = ["dom-breadth", "live-intervals"] as const satisfies readonly PerfBudgetClass[];
export type GatedClass = (typeof GATED_CLASSES)[number];

/** One violation as the page script reports it. `id` is unique per document, so a hit read twice counts once. */
export type GateHit = { id: string; kind: GatedClass; site: string; message: string; url: string };

/**
 * The name a hit is counted under: the same on every machine and every run. A node's description
 * (`ul.projects`) stays as it is. A call site (`useTick (http://127.0.0.1:41234/src/ui/x.ts?t=1:12:5)`)
 * keeps only its file: no origin or port, no query, no line and column, no build hash in a chunk
 * name, and no function name (a production bundle renames functions from build to build).
 */
export function siteKey(kind: GatedClass, site: string): string {
  const flat = site.replace(/\s+/g, " ").trim();
  if (kind !== "live-intervals") return flat;
  // The location: the parenthesized part when there is a function name, the whole frame otherwise.
  const location = /\(([^()]*)\)\s*$/.exec(flat)?.[1] ?? flat;
  return (
    location
      .replace(/^(?:https?:\/\/[^/]+|file:\/\/)/, "")
      // Vite serves a file outside its root as /@fs/<absolute path>; any absolute checkout path
      // keeps only what follows webviews/.
      .replace(/^.*?\/webviews\//, "")
      .replace(/^\/@fs\//, "/")
      .replace(/[?#].*$/, "")
      .replace(/(?::\d+){1,2}$/, "")
      .replace(/-[A-Za-z0-9_-]{8}(?=\.m?js$)/, "")
      .replace(/^\//, "") || "unknown"
  );
}

/** A baseline row's key: test file, class and site, tab-separated. */
export const rowKey = (file: string, kind: string, site: string) => `${file}\t${kind}\t${site}`;
export const rowFile = (key: string) => key.slice(0, key.indexOf("\t"));

const HEADER =
  "# Perf budget hits in the browser tests from before the gate (test/support/perfBudgetGate.ts). Only moves down.\n" +
  "# test file\tclass\tsite\tcount (documents the budget fired in)\n";

export function parseBaseline(text: string): Map<string, number> {
  const rows = new Map<string, number>();
  for (const line of text.split("\n")) {
    if (!line.trim() || line.startsWith("#")) continue;
    const [file, kind, site, count] = line.split("\t");
    if (!file || !kind || !site || !/^\d+$/.test(count ?? ""))
      throw new Error(`perf-budget-baseline.tsv: bad row "${line}"`);
    rows.set(rowKey(file, kind, site), Number(count));
  }
  return rows;
}

export function formatBaseline(rows: Map<string, number>): string {
  const lines = [...rows]
    .filter(([, count]) => count > 0)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([key, count]) => `${key}\t${count}`);
  return HEADER + lines.map((line) => `${line}\n`).join("");
}

/** A test file's hits counted by row key. */
export function countHits(file: string, hits: Iterable<Pick<GateHit, "kind" | "site">>): Map<string, number> {
  const counts = new Map<string, number>();
  for (const hit of hits) {
    const key = rowKey(file, hit.kind, siteKey(hit.kind, hit.site));
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

export type Judgement = {
  /** Rows above the baseline: `key`, the count and the baseline's count. */
  grew: { key: string; count: number; baseline: number }[];
  /** Rows below the baseline, for a run that ran the whole file. */
  shrank: { key: string; count: number; baseline: number }[];
};

/**
 * One test file's counts against the baseline's rows for it. A row above its baseline grew; a row
 * below it (or missing) shrank, judged only when the run was the whole file (a `-t` filter, or a
 * run that never opened a browser, would read as a fix).
 */
export function judge(
  file: string,
  counts: Map<string, number>,
  baseline: Map<string, number>,
  { whole }: { whole: boolean },
): Judgement {
  const grew: Judgement["grew"] = [];
  const shrank: Judgement["shrank"] = [];
  const keys = new Set([...counts.keys(), ...[...baseline.keys()].filter((key) => rowFile(key) === file)]);
  for (const key of [...keys].sort()) {
    const count = counts.get(key) ?? 0;
    const before = baseline.get(key) ?? 0;
    if (count > before) grew.push({ key, count, baseline: before });
    else if (whole && count < before) shrank.push({ key, count, baseline: before });
  }
  return { grew, shrank };
}

/**
 * The baseline after the observed runs of some test files: each file's rows become its counts. A
 * count above its row is refused (the baseline only shrinks), and then nothing is written. With no
 * baseline yet (`seed`), every count is taken.
 */
export function lowerBaseline(
  baseline: Map<string, number>,
  observed: Map<string, Map<string, number>>,
  { seed = false }: { seed?: boolean } = {},
): { rows: Map<string, number>; refused: Judgement["grew"] } {
  const refused: Judgement["grew"] = [];
  const rows = new Map(baseline);
  for (const [file, counts] of observed) {
    if (!seed) refused.push(...judge(file, counts, baseline, { whole: true }).grew);
    // Deleting the entry being visited is safe in a Map's iteration.
    for (const key of rows.keys()) if (rowFile(key) === file) rows.delete(key);
    for (const [key, count] of counts) rows.set(key, count);
  }
  return { rows: refused.length > 0 ? new Map(baseline) : rows, refused };
}
