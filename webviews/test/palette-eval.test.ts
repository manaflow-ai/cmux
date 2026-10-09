import { describe, expect, test } from "bun:test";
import { formatReport, evaluate } from "../src/palette/eval";
import { loadEval } from "../scripts/palette-eval";

// The palette ranking eval (plans/cmux-next/palette-ranking.md section 3): real root-palette
// entries, 112 queries with expected rows. A ranking change must not lower these floors; raise
// them when a change improves the numbers, and paste the report into the landing.
// Recorded 2026-10-09 with the tiered scorer and commands-first ties (palette-ranking.md section 6, step 2b).
const floors = { top1: 0.68, top3: 0.79, mrr: 0.755 };

describe("palette ranking eval", () => {
  const { fixture, cases } = loadEval();

  test("every expected row exists in the fixture", () => {
    const ids = new Set(fixture.entries.map((row) => row.id));
    const missing = cases.cases.flatMap((c) => (c.expect.some((id) => ids.has(id)) ? [] : [c.query]));
    expect(missing).toEqual([]);
  });

  test("ranking quality stays at or above the recorded floors", () => {
    const report = evaluate(fixture, cases);
    console.log(formatReport(report));
    expect(report.top1).toBeGreaterThanOrEqual(floors.top1);
    expect(report.top3).toBeGreaterThanOrEqual(floors.top3);
    expect(report.mrr).toBeGreaterThanOrEqual(floors.mrr);
  });
});
