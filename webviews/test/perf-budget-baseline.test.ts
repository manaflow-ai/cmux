// The browser test gate's baseline logic (support/perfBudgetBaseline.ts, support/perfBudgetGate.ts
// readRun, scripts/perf-budget-baseline.ts): hits counted under names that hold across machines and
// builds, a file failing above its rows and (on a whole run) below them, and a baseline that the
// update only lowers. perf-budget-gate.browser.test.ts runs it in a browser.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { readObserved } from "../scripts/perf-budget-baseline";
import {
  countHits,
  formatBaseline,
  GATED_CLASSES,
  judge,
  lowerBaseline,
  parseBaseline,
  rowKey,
  siteKey,
} from "./support/perfBudgetBaseline";
import { readRun } from "./support/perfBudgetGate";

const FILE = "test/a.browser.test.ts";

describe("siteKey", () => {
  test("a node's description stays as it is", () => {
    expect(siteKey("dom-breadth", "ul.projects")).toBe("ul.projects");
    expect(siteKey("dom-breadth", "div (history)")).toBe("div (history)");
  });

  test("a call site keeps only its file: no origin, port, query, line, function name or build hash", () => {
    expect(siteKey("live-intervals", "t0 (http://127.0.0.1:40811/test/browser/perf-budgets.harness.tsx:129:18)")).toBe(
      "test/browser/perf-budgets.harness.tsx",
    );
    expect(siteKey("live-intervals", "http://127.0.0.1:4200/src/ui/clock.ts?t=1712:3:9")).toBe("src/ui/clock.ts");
    expect(siteKey("live-intervals", "Xe (http://127.0.0.1:9/chunks/index-B2x_aZ9q.js:1:5000)")).toBe(
      "chunks/index.js",
    );
    expect(siteKey("live-intervals", "a (file:///home/runner/work/cmux/cmux/webviews/dist/gallery/app.js:4:2)")).toBe(
      "dist/gallery/app.js",
    );
    expect(siteKey("live-intervals", "b (http://127.0.0.1:5/@fs/Users/me/cmux/webviews/src/x.ts:1:1)")).toBe(
      "src/x.ts",
    );
  });

  test("only the classes that count gate; none of them times anything", () => {
    expect([...GATED_CLASSES]).toEqual(["dom-breadth", "live-intervals"]);
  });
});

describe("judge", () => {
  const hits = [
    { kind: "dom-breadth" as const, site: "ul.projects" },
    { kind: "dom-breadth" as const, site: "ul.projects" },
    { kind: "live-intervals" as const, site: "f (http://127.0.0.1:1/src/x.ts:1:1)" },
  ];
  const counts = countHits(FILE, hits);

  test("counts hits per row", () => {
    expect([...counts]).toEqual([
      [rowKey(FILE, "dom-breadth", "ul.projects"), 2],
      [rowKey(FILE, "live-intervals", "src/x.ts"), 1],
    ]);
  });

  test("a row above its baseline grew; a new row is above zero", () => {
    const baseline = new Map([[rowKey(FILE, "dom-breadth", "ul.projects"), 1]]);
    const { grew, shrank } = judge(FILE, counts, baseline, { whole: true });
    expect(grew.map((row) => [row.key, row.count, row.baseline])).toEqual([
      [rowKey(FILE, "dom-breadth", "ul.projects"), 2, 1],
      [rowKey(FILE, "live-intervals", "src/x.ts"), 1, 0],
    ]);
    expect(shrank).toEqual([]);
  });

  test("a row below its baseline shrank on a whole run only; other files' rows are not this file's", () => {
    const baseline = new Map([
      [rowKey(FILE, "dom-breadth", "ul.projects"), 3],
      [rowKey(FILE, "live-intervals", "src/x.ts"), 1],
      [rowKey(FILE, "dom-breadth", "ol.gone"), 1],
      [rowKey("test/other.test.ts", "dom-breadth", "ul.projects"), 9],
    ]);
    const whole = judge(FILE, counts, baseline, { whole: true });
    expect(whole.grew).toEqual([]);
    expect(whole.shrank.map((row) => [row.key, row.count, row.baseline])).toEqual([
      [rowKey(FILE, "dom-breadth", "ol.gone"), 0, 1],
      [rowKey(FILE, "dom-breadth", "ul.projects"), 2, 3],
    ]);
    expect(judge(FILE, counts, baseline, { whole: false }).shrank).toEqual([]);
  });
});

describe("the baseline file", () => {
  test("round-trips, sorted, without zero rows", () => {
    const rows = new Map([
      [rowKey("test/b.test.ts", "dom-breadth", "ul.x"), 2],
      [rowKey(FILE, "live-intervals", "src/x.ts"), 1],
      [rowKey(FILE, "dom-breadth", "ol.y"), 0],
    ]);
    const text = formatBaseline(rows);
    expect(text.split("\n").filter((line) => line && !line.startsWith("#"))).toEqual([
      `${FILE}\tlive-intervals\tsrc/x.ts\t1`,
      "test/b.test.ts\tdom-breadth\tul.x\t2",
    ]);
    expect(parseBaseline(text)).toEqual(new Map([...rows].filter(([, count]) => count > 0)));
  });

  test("a bad row is an error, not a row", () => {
    expect(() => parseBaseline(`${FILE}\tdom-breadth\tul.x\tmany\n`)).toThrow("bad row");
  });

  test("the update lowers and drops a file's rows, refuses to raise one, and seeds an empty baseline", () => {
    const baseline = new Map([
      [rowKey(FILE, "dom-breadth", "ul.projects"), 3],
      [rowKey(FILE, "dom-breadth", "ol.gone"), 1],
      [rowKey("test/other.test.ts", "dom-breadth", "ul.x"), 4],
    ]);
    const lowered = lowerBaseline(
      baseline,
      new Map([[FILE, new Map([[rowKey(FILE, "dom-breadth", "ul.projects"), 1]])]]),
    );
    expect(lowered.refused).toEqual([]);
    expect(lowered.rows).toEqual(
      new Map([
        [rowKey("test/other.test.ts", "dom-breadth", "ul.x"), 4],
        [rowKey(FILE, "dom-breadth", "ul.projects"), 1],
      ]),
    );
    const raised = lowerBaseline(baseline, new Map([[FILE, new Map([[rowKey(FILE, "dom-breadth", "new.one"), 1]])]]));
    expect(raised.refused.map((row) => row.key)).toEqual([rowKey(FILE, "dom-breadth", "new.one")]);
    expect(raised.rows).toEqual(baseline);
    const seeded = lowerBaseline(new Map(), new Map([[FILE, new Map([[rowKey(FILE, "dom-breadth", "a"), 2]])]]), {
      seed: true,
    });
    expect(seeded.refused).toEqual([]);
    expect(seeded.rows.get(rowKey(FILE, "dom-breadth", "a"))).toBe(2);
  });

  const dir = mkdtempSync(path.join(tmpdir(), "perf-budget-observed-"));
  afterAll(() => rmSync(dir, { recursive: true, force: true }));
  test("a run's counts file names its test file; one with no rows had no hits", () => {
    writeFileSync(path.join(dir, "test__a.tsv"), `# ${FILE}\n${FILE}\tdom-breadth\tul.x\t2\n`);
    writeFileSync(path.join(dir, "test__b.tsv"), "# test/b.test.ts\n");
    expect(readObserved(dir)).toEqual(
      new Map([
        [FILE, new Map([[rowKey(FILE, "dom-breadth", "ul.x"), 2]])],
        ["test/b.test.ts", new Map()],
      ]),
    );
    writeFileSync(path.join(dir, "test__c.tsv"), `# test/c.test.ts\n${FILE}\tdom-breadth\tul.x\t2\n`);
    expect(() => readObserved(dir)).toThrow("a row of");
  });
});

describe("readRun", () => {
  const webviews = path.resolve(import.meta.dir, "..");
  const main = path.join(webviews, "test/perf-budget-baseline.test.ts");
  const bun = "/usr/bin/bun";
  test("one named file and no filter is a whole single-file run", () => {
    const cwd = process.cwd();
    process.chdir(webviews);
    try {
      expect(readRun(main, [bun, "test", "--timeout", "120000", "./test/perf-budget-baseline.test.ts"])).toEqual({
        file: "test/perf-budget-baseline.test.ts",
        single: true,
        whole: true,
      });
      expect(readRun(main, [bun, "test", "./test/perf-budget-baseline.test.ts", "-t", "siteKey"]).whole).toBe(false);
      expect(
        readRun(main, [bun, "test", "./test/perf-budget-baseline.test.ts", "--test-name-pattern=siteKey"]).whole,
      ).toBe(false);
      // Two files share one process's hooks: neither is judged alone.
      expect(
        readRun(main, [bun, "test", "./test/perf-budget-baseline.test.ts", "./test/perf-budgets.browser.test.ts"])
          .single,
      ).toBe(false);
      // A filter that is not a file may match several.
      expect(readRun(main, [bun, "test", "perf-budget"]).single).toBe(false);
    } finally {
      process.chdir(cwd);
    }
    // No command line to read (not Linux): judged alone, never as a whole run.
    expect(readRun(main, null)).toEqual({ file: "test/perf-budget-baseline.test.ts", single: true, whole: false });
  });
});
