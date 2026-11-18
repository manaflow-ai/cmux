// The browser test gate (support/perfBudgetGate.ts) end to end: a test file whose page draws a
// 1000-row list whole (#36132) fails through the gate alone, the same list drawn through VirtualList
// passes, a baseline row lets the old hit through, and a row the fix made stale fails until
// scripts/perf-budget-baseline.ts lowers it (which refuses to raise one). Each case runs
// test/browser/perf-budget-gate.fixture.ts in its own `bun test`, the way CI runs every file, with
// its own baseline file.
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("perf-budget-gate.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const FIXTURE = "test/browser/perf-budget-gate.fixture.ts";
  const ROW = `${FIXTURE}\tdom-breadth\tul.projects`;
  const dir = mkdtempSync(path.join(tmpdir(), "perf-budget-gate-"));
  afterAll(() => rmSync(dir, { recursive: true, force: true }));
  let runs = 0;

  /** Runs the fixture on `kase` against a baseline holding `rows`; its exit code, output and counts. */
  async function gate(kase: string, rows: string[]) {
    const run = path.join(dir, String(runs++));
    const baseline = path.join(run, "baseline.tsv");
    const observed = path.join(run, "observed");
    await Bun.write(baseline, rows.map((row) => `${row}\n`).join(""));
    const child = Bun.spawn([process.execPath, "test", `./${FIXTURE}`], {
      cwd: webviews,
      env: {
        ...process.env,
        CMUX_BROWSER_TESTS: "1",
        PERF_GATE_CASE: kase,
        CMUX_PERF_BUDGET_BASELINE_FILE: baseline,
        CMUX_PERF_BUDGET_OBSERVED: observed,
      },
      stdout: "pipe",
      stderr: "pipe",
    });
    const [out, err, code] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    return { code, output: out + err, baseline, observed };
  }

  /** scripts/perf-budget-baseline.ts --update on a run's counts and baseline. */
  async function update(run: { baseline: string; observed: string }) {
    const child = Bun.spawn([process.execPath, "scripts/perf-budget-baseline.ts", "--update", run.observed], {
      cwd: webviews,
      env: { ...process.env, CMUX_PERF_BUDGET_BASELINE_FILE: run.baseline },
      stdout: "pipe",
      stderr: "pipe",
    });
    const [out, err, code] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    return { code, output: out + err, rows: readFileSync(run.baseline, "utf8") };
  }

  test("a 1000-row list drawn whole fails the file through the gate, naming the element and the fix", async () => {
    const run = await gate("whole-list", []);
    expect(run.code).not.toBe(0);
    expect(run.output).toContain("dom-breadth at ul.projects: 1 (baseline 0)");
    expect(run.output).toContain("1000 children over the budget of 300 children at ul.projects");
    expect(run.output).toContain("VirtualList");
    // A count above its row is not written into the baseline for you.
    const raised = await update(run);
    expect(raised.code).toBe(1);
    expect(raised.output).toContain("refusing to raise");
    expect(raised.rows).toBe("");
  });

  test("the same list through VirtualList passes", async () => {
    const run = await gate("windowed-list", []);
    expect(run.output).not.toContain("perf budget gate");
    expect(run.code).toBe(0);
  });

  test("a hit on the baseline passes; once fixed, its row fails until it is lowered", async () => {
    const old = await gate("whole-list", [`${ROW}\t1`]);
    expect(old.output).not.toContain("perf budget gate");
    expect(old.code).toBe(0);

    const fixed = await gate("windowed-list", [`${ROW}\t1`]);
    expect(fixed.code).not.toBe(0);
    expect(fixed.output).toContain("less often than");
    expect(fixed.output).toContain("dom-breadth at ul.projects: 0 (baseline 1)");
    const lowered = await update(fixed);
    expect(lowered.code).toBe(0);
    expect(lowered.rows).not.toContain("ul.projects");
  });
});
