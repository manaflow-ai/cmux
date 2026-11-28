import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { render, runExperiment } from "./counterfactual-exp.ts";

let root: string;
let result: Awaited<ReturnType<typeof runExperiment>>;

beforeAll(async () => {
  root = mkdtempSync(join(tmpdir(), "cf-exp-test-"));
  result = await runExperiment(root);
}, 180_000);

afterAll(() => rmSync(root, { recursive: true, force: true }));

describe("counterfactual workbench experiment", () => {
  test("five paired tasks fork turn 1 exactly into an isolated worktree with its context", () => {
    expect(result.rows).toHaveLength(5);
    for (const row of [...result.rows, result.trap]) {
      expect(row.fork.exact).toBe(true);
      expect(row.fork.isolated).toBe(true);
      expect(row.fork.actions).toBe(1);
      expect(row.fork.capsuleTurns).toBe(1);
      expect(row.fork.lineage.checkpoint).toStartWith("refs/cmux/checkpoints/");
      expect(row.checkpointPerTurn.map((c) => c.turn)).toEqual([1, 2, 3]);
      expect(row.checkpointPerTurn[0].excluded).toContain(".env");
      expect(row.original.pass).toBe(true);
      expect(row.adopt.ontoBase).toBe(true);
    }
  });

  test("a gitHead-only record loses the turn's uncommitted files; setup effort is >= 2x", () => {
    const uncommitted = result.rows.filter((r) => !r.manual.exact);
    expect(uncommitted.map((r) => r.task)).toEqual(["sum", "parseConfig", "fizz"]);
    for (const row of uncommitted) expect(row.manual.missing).toContain("lib.js");
    for (const row of result.rows) expect(row.manual.actions / row.fork.actions).toBeGreaterThanOrEqual(2);
  });

  test("outcomes diverge: one alternative fails its smoke test, adopting onto the original conflicts", () => {
    const slug = result.rows.find((r) => r.task === "slugify")!;
    expect(slug.alternative.pass).toBe(false);
    expect(result.rows.filter((r) => r.alternative.pass)).toHaveLength(4);
    for (const row of result.rows) expect(row.adopt.ontoOriginal).toBe(false);
  });

  test("the external side effect is reported as not undone and the fork's own attempt is blocked", () => {
    const x = result.trap.external!;
    expect(x.undone).toBe(false);
    expect(x.stillPresent).toBe(true);
    expect(x.serverHits).toBe(1);
    expect(x.hitsAfterFork).toBe(1);
    expect(x.blockedInFork.length).toBe(2);
  });

  test("an incomplete checkpoint refuses an exact fork and an approximate one says so", () => {
    expect(result.refusal.complete).toBe(false);
    expect(result.refusal.refused).toStartWith("checkpoint_incomplete");
    expect(result.refusal.approximate.exact).toBe(false);
    expect(result.refusal.approximate.missing).toEqual(["fixture.bin"]);
    expect(result.refusal.approximate.hasLib).toBe(true);
  });

  test("renders a side-by-side table", () => {
    const text = render(result);
    expect(text).toContain("| slugify |");
    expect(text).toContain("undone=false");
  });
});
