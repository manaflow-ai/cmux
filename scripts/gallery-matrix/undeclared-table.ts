#!/usr/bin/env bun
// The layout-motion scenario table from one gallery run: each state's undeclared moves (the worst case of
// its widths and engines), split by phase, as a Markdown table. The run is the gallery matrix runner's on the
// fleet, e.g. from webviews/:
//
//   cmux-ci test --setup playwright --artifact /tmp/motion -- 'bash scripts/gallery-matrix/undeclared-run.sh'
//
// which renders `layout.motion-scenarios` (and any entries named in ENTRIES) with video, then
//
//   bun undeclared-table.ts --results <dir with results.json>
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { caseCount, type UndeclaredResult } from "./undeclared-baseline";

type Result = UndeclaredResult & { engine?: string; video?: string; screenshot?: string };

export function table(results: Result[]): string {
  const rows = new Map<string, { count: number; moves: string[]; cases: number }>();
  for (const result of results) {
    if (result.ready !== "1") continue;
    const state = `${String(result.params?.entry ?? "")}#${String(result.params?.variant ?? "")}`;
    const counted = caseCount(result);
    const seen = rows.get(state);
    if (!seen) rows.set(state, { ...counted, cases: 1 });
    else {
      seen.cases += 1;
      if (counted.count > seen.count) Object.assign(seen, counted);
    }
  }
  const lines = ["| scenario | undeclared moves | cases | first moves |", "|---|---|---|---|"];
  for (const [state, { count, moves, cases }] of [...rows].sort(([a], [b]) => a.localeCompare(b)))
    lines.push(`| ${state} | ${count} | ${cases} | ${moves.join("; ").replace(/\|/g, "/") || ""} |`);
  return lines.join("\n");
}

if (import.meta.main) {
  const { values } = parseArgs({ options: { results: { type: "string" } } });
  if (!values.results) throw new Error("--results <dir with results.json> is required");
  const results = JSON.parse(readFileSync(join(values.results, "results.json"), "utf8")) as Result[];
  console.log(table(results));
  // With DETAIL=1 (undeclared-run.sh), every undeclared move of every case, as the judge reported it.
  if (process.env.DETAIL === "1")
    for (const result of results)
      for (const phase of [result.load, ...(result.play?.steps ?? [])])
        for (const move of phase?.undeclaredMoves ?? [])
          console.log(`undeclared ${String(result.params?.variant ?? "")} w${String(result.params?.width ?? "")} ${phase?.step ?? "load"}: ${JSON.stringify(move)}`);
}
