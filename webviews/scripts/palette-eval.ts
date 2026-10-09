/**
 * Prints the palette ranking eval report (plans/cmux-next/palette-ranking.md).
 *
 *   bun scripts/palette-eval.ts                 # the shared ranker over the checked-in fixture
 *   bun scripts/palette-eval.ts --live FILE     # rows a tagged build returned (palette-eval-live.py)
 *   bun scripts/palette-eval.ts --json          # the full report as JSON
 *   bun scripts/palette-eval.ts --fixture F --ranker M   # A/B: another dump, or another ranker module
 *   bun scripts/palette-eval.ts --explain "query"         # the top 12 rows with scores and sections
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  evaluate,
  formatReport,
  mergeOverlay,
  scoreCases,
  type EvalCases,
  type EvalFixture,
  type EvalOverlayEntry,
  type Ranker,
} from "../src/palette/eval";
import { rankPalette } from "../src/palette/ranker";

const root = join(import.meta.dir, "..", "test", "fixtures", "palette-eval");
const read = <T>(path: string): T => JSON.parse(readFileSync(path, "utf8")) as T;

export function loadEval(fixturePath = join(root, "root-entries.json")) {
  const fixture = mergeOverlay(
    read<EvalFixture>(fixturePath),
    read<EvalOverlayEntry[]>(join(root, "overlay.json")),
  );
  return { fixture, cases: read<EvalCases>(join(root, "cases.json")) };
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const option = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
  const { fixture, cases } = loadEval(option("--fixture"));
  const rankerPath = option("--ranker");
  const rank = rankerPath ? ((await import(rankerPath)) as { rankPalette: Ranker }).rankPalette : undefined;
  const explain = option("--explain");
  if (explain !== undefined) {
    const sections = (rank ?? rankPalette)({
      entries: fixture.entries.map((row) => row.entry),
      query: explain,
      sectionOrders: fixture.sectionOrders,
      frecency: { entries: {} },
      now: 0,
      showsRecent: fixture.showsRecent,
    });
    for (const section of sections)
      for (const row of section.rows.slice(0, 12))
        console.log(
          `${String(row.score).padStart(6)}  ${(section.sectionIndex === null ? "recent" : fixture.sections[section.sectionIndex].id).padEnd(12)} ${fixture.entries[row.index].id}  ${JSON.stringify(fixture.entries[row.index].entry.title)}`,
        );
    process.exit(0);
  }
  const liveIndex = args.indexOf("--live");
  let report;
  if (liveIndex >= 0) {
    const live = read<{ tag: string; results: Record<string, Array<{ id: string }> | { error: unknown }> }>(args[liveIndex + 1]);
    // Live rows come from a fresh build: no usage, no overlay rows. Only cases without a profile
    // whose expected rows exist in that build are scored.
    const ids = new Set(read<EvalFixture>(join(root, "root-entries.json")).entries.map((row) => row.id));
    const liveCases: EvalCases = {
      cases: cases.cases.filter(
        (c) => !c.profile && c.query !== "" && c.query in live.results && c.expect.some((id) => ids.has(id)),
      ),
    };
    report = scoreCases(liveCases, (query) => {
      const rows = live.results[query];
      return Array.isArray(rows) ? rows.map((row) => row.id) : [];
    });
    console.log(args.includes("--json") ? JSON.stringify(report, null, 1) : formatReport(report, `live ${live.tag}`));
  } else {
    report = evaluate(fixture, cases, rank);
    console.log(args.includes("--json") ? JSON.stringify(report, null, 1) : formatReport(report));
  }
}
