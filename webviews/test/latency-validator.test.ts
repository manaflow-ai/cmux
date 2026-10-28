import { expect, test } from "bun:test";
import { formatReport } from "../scripts/latency/report";
import { validateEvidence, type BudgetConfig } from "../scripts/latency/validate";

const budget: BudgetConfig = {
  schemaVersion: 1,
  maxP95Ms: 50,
  maxRegressionRatio: 0.15,
  maxRegressionDeltaMs: 5,
  topN: 10,
};
const id = "chromium/picker/open";
const source = {
  repository: "https://github.com/manaflow-ai/cmux.git",
  head: "a".repeat(40),
  base: "b".repeat(40),
  browsers: [{ engine: "chromium", version: "131" }],
  runner: { platform: "linux" },
  mode: "production",
  dirty: false,
};
function evidence(p95 = 20): any {
  return {
    schemaVersion: 1,
    source,
    expectedCases: [id],
    runs: 10,
    errors: [],
    results: [
      {
        id,
        engine: "chromium",
        metricType: "target_painted",
        latencyMs: { p50: 10, p95, max: p95 },
        samples: [{ work: 1 }],
        errors: [],
        longTasks: { count: 0, totalMs: 0, maxMs: 0, source: "PerformanceObserver longtask" },
        reactCommits: 1,
        idle: { sampleDurationMs: 1000, cpuDurationMs: 20, cpuPercent: 2, wakeups: null },
        framesSummary: { count: 1, dropped: 0, maxGapMs: 10 },
        unsupportedReasons: { wakeups: "wakeups unavailable; context switches are not wakeups" },
      },
    ],
  };
}
function baseline(p95 = 20): any {
  return {
    schemaVersion: 1,
    status: "ready",
    source: { repository: source.repository, head: source.base },
    expectedCases: [id],
    results: { [id]: { p50: 10, p95, max: p95 } },
  };
}

test("pending baseline fails closed with an actionable hosted-run explanation", () => {
  const result = validateEvidence(
    evidence(),
    { schemaVersion: 1, status: "pending", reason: "capture first hosted run", source: null, results: {} },
    budget,
    { expectedHead: source.head },
  );
  expect(result.ok).toBe(false);
  expect(result.errors.some((error) => error.includes("baseline is pending"))).toBe(true);
});

test("strict evidence rejects missing cases, errors, and required instrumentation", () => {
  const candidate = evidence();
  candidate.expectedCases = [id, "chromium/chat/send"];
  candidate.errors = ["timed out"];
  candidate.results[0].longTasks = null;
  candidate.results[0].reactCommits = null;
  candidate.results[0].idle.cpuDurationMs = null;
  const result = validateEvidence(candidate, baseline(), budget, { expectedHead: source.head });
  expect(result.ok).toBe(false);
  expect(result.errors.join("\n")).toMatch(
    /missing result|harness: timed out|required longTasks|required reactCommits|required idle/,
  );
});

test("exact base pairing and p95 budget/regression are enforced", () => {
  const result = validateEvidence(evidence(60), baseline(20), budget, { expectedHead: source.head });
  expect(result.ok).toBe(false);
  expect(result.errors.some((error) => error.includes("regression allowance"))).toBe(true);
  expect(result.errors.some((error) => error.includes("exceeds 50.0ms"))).toBe(true);
  const mismatched = validateEvidence(
    { ...evidence(), source: { ...source, base: "c".repeat(40) } },
    baseline(),
    budget,
    { expectedHead: source.head },
  );
  expect(mismatched.errors.some((error) => error.includes("does not match results source.base"))).toBe(true);
});

test("report includes the PR number, exact heads, and worst-case row", () => {
  const result = validateEvidence(evidence(), baseline(), budget, { expectedHead: source.head });
  const report = formatReport(result, "1234");
  expect(report).toContain("PR #1234");
  expect(report).toContain(source.head);
  expect(report).toContain(id);
});

test("drag target paint and frame cadence remain distinct accepted metric types", () => {
  const candidate = evidence();
  candidate.results[0].metricType = "drag_target_painted";
  candidate.results[0].adapterRuns = [
    {
      status: "complete",
      observations: [
        {
          status: "painted",
          latencyMs: 12,
          inputAt: 10,
          targetPaintAt: 22,
          raw: { releaseToPaintMs: 3, lastMoveToPaintMs: 5, alreadyPaintedBeforeRelease: false },
        },
      ],
      frameGaps: [8],
      longTasks: [],
      reactCommits: 1,
      unsupportedReasons: {},
    },
  ];
  expect(validateEvidence(candidate, baseline(), budget, { expectedHead: source.head }).ok).toBe(true);
  candidate.results[0].metricType = "frame_time";
  expect(validateEvidence(candidate, baseline(), budget, { expectedHead: source.head }).ok).toBe(true);
});
