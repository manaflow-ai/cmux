import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { formatReport } from "../scripts/latency/report";
import { validateEvidence, type BudgetConfig } from "../scripts/latency/validate";
import { captureBaseline } from "../scripts/latency/bootstrap";

const budget: BudgetConfig = {
  minRuns: 10,
  cpuThrottle: 1,
  metricTypes: { "chromium/picker/open": "target_painted" },
  expectedCases: ["chromium/picker/open"],
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
    cpuThrottle: 1,
    errors: [],
    results: [
      {
        id,
        engine: "chromium",
        metricType: "target_painted",
        latencyMs: { p50: p95, p95, max: p95 },
        samples: Array.from({ length: 10 }, () => ({
          work: 1,
          paint: p95,
          frameGaps: [p95],
          longTasks: [],
          reactCommits: 1,
          instrumentation: { longTasks: true },
        })),
        errors: [],
        longTasks: { count: 0, totalMs: 0, maxMs: 0, source: "PerformanceObserver longtask" },
        reactCommits: 10,
        idle: {
          dataSource: "CDP Performance.ThreadTime (threadTicks): renderer main-thread CPU",
          sampleDurationMs: 1000,
          cpuDurationMs: 20,
          cpuPercent: 2,
          wakeups: null,
          unsupportedReasons: { wakeups: "no real wakeup source" },
        },
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
    results: { [id]: { p50: p95, p95, max: p95 } },
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

test("exact live base and p95 budget/regression are enforced", () => {
  const result = validateEvidence(evidence(60), baseline(20), budget, { expectedHead: source.head });
  expect(result.ok).toBe(false);
  expect(result.errors.some((error) => error.includes("regression allowance"))).toBe(true);
  expect(result.errors.some((error) => error.includes("exceeds 50.0ms"))).toBe(true);
  const mismatched = validateEvidence(
    { ...evidence(), source: { ...source, base: "c".repeat(40) } },
    baseline(),
    budget,
    { expectedHead: source.head, expectedBase: source.base },
  );
  expect(mismatched.errors.some((error) => error.includes("results base"))).toBe(true);
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
  candidate.results[0].samples = [];
  candidate.results[0].latencyMs = { p50: 12, p95: 12, max: 12 };
  candidate.results[0].adapterRuns = Array.from({ length: 10 }, () => ({
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
  }));
  expect(
    validateEvidence(
      candidate,
      baseline(),
      { ...budget, metricTypes: { [id]: candidate.results[0].metricType } },
      { expectedHead: source.head },
    ).ok,
  ).toBe(true);
  candidate.results[0].metricType = "frame_time";
  candidate.results[0].latencyMs = { p50: 8, p95: 8, max: 8 };
  expect(
    validateEvidence(
      candidate,
      baseline(),
      { ...budget, metricTypes: { [id]: candidate.results[0].metricType } },
      { expectedHead: source.head },
    ).ok,
  ).toBe(true);
});

test("the trusted manifest rejects omitted cases even when the candidate rewrites its own expected list", () => {
  const candidate = evidence();
  candidate.expectedCases = [];
  candidate.results = [];
  expect(validateEvidence(candidate, baseline(), budget).errors.join("\n")).toContain("trusted budget.expectedCases");
});

test("trusted policy pins metric units, run count, throttle, and the strict 50ms limit", () => {
  const candidate = evidence();
  candidate.results[0].metricType = "frame_time";
  expect(validateEvidence(candidate, baseline(), budget).errors.join("\n")).toContain("metricType does not match");
  candidate.results[0].metricType = "target_painted";
  candidate.cpuThrottle = 4;
  expect(validateEvidence(candidate, baseline(), budget).errors.join("\n")).toContain("CPU throttle");
  candidate.cpuThrottle = 1;
  candidate.runs = 1;
  candidate.results[0].samples = candidate.results[0].samples.slice(0, 1);
  candidate.results[0].reactCommits = 1;
  expect(validateEvidence(candidate, baseline(), budget).errors.join("\n")).toContain("at least 10 runs");
  expect(validateEvidence(evidence(50), baseline(50), budget).ok).toBe(false);
});

test("baseline provenance survives a newer live base while that live base remains exact", () => {
  const candidate = evidence();
  candidate.source = { ...source, base: "c".repeat(40) };
  const result = validateEvidence(candidate, baseline(), budget, {
    expectedHead: source.head,
    expectedBase: candidate.source.base,
  });
  expect(result.ok).toBe(true);
  expect(result.baselineHead).toBe(source.base);
  expect(result.base).toBe(candidate.source.base);
});

test("numeric summaries must agree with raw observations and preserve the requested run count", () => {
  const candidate = evidence();
  candidate.results[0].latencyMs.p95 = 1;
  expect(validateEvidence(candidate, baseline(), budget).ok).toBe(false);
  candidate.results[0].latencyMs = { p50: 20, p95: 20, max: 20 };
  candidate.results[0].samples.pop();
  expect(validateEvidence(candidate, baseline(), budget).errors.join("\n")).toContain("expected 10 raw samples");
});

test("closed or unreadable fixing PR exceptions fail closed", () => {
  const prior = baseline();
  prior.results[id].fixingPr = "#12345";
  expect(validateEvidence(evidence(60), prior, budget).ok).toBe(false);
  expect(validateEvidence(evidence(60), prior, budget, { verifiedOpenPrs: [12345] }).ok).toBe(true);
});

test("bootstrap retains actual over-budget numbers without manufacturing an exception", () => {
  const captured = captureBaseline(evidence(60), budget, {
    expectedHead: source.head,
    expectedBase: source.base,
    artifactUrl: "https://github.com/manaflow-ai/cmux/actions/runs/12345",
    evidenceSha256: "d".repeat(64),
  });
  expect(captured.results[id].p95).toBe(60);
  expect(captured.results[id].fixingPr).toBeUndefined();
  expect(validateEvidence(evidence(60), captured, budget).ok).toBe(false);
  expect(() =>
    captureBaseline({ ...evidence(), errors: ["incomplete"] }, budget, {
      expectedHead: source.head,
      expectedBase: source.base,
      artifactUrl: "https://github.com/manaflow-ai/cmux/actions/runs/12345",
      evidenceSha256: "d".repeat(64),
    }),
  ).toThrow("incomplete");
});

test.each(["missing", "digest", "empty"])("required raw trace rejects %s artifact data", (failure) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "latency-trace-test-"));
  try {
    const candidate = evidence();
    const raw = JSON.stringify({ traceEvents: failure === "empty" ? [] : [{ name: "Paint", ts: 1, ph: "X" }] });
    const file = path.join(directory, "case.trace.json");
    fs.writeFileSync(file, raw);
    candidate.results[0].rawTrace = {
      path: "case.trace.json",
      bytes: Buffer.byteLength(raw),
      sha256: createHash("sha256").update(raw).digest("hex"),
    };
    if (failure === "missing") fs.rmSync(file);
    if (failure === "digest") fs.writeFileSync(file, raw.replace("Paint", "Other"));
    const options = { expectedHead: source.head, traceDir: directory };
    const result = validateEvidence(candidate, baseline(), { ...budget, rawTraceRequired: true }, options);
    expect(result.ok).toBe(false);
    expect(result.errors.join("\n")).toMatch(/raw trace|timeline/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("required raw traces need actual files even when all metadata is present", () => {
  const candidate = evidence();
  candidate.results[0].rawTrace = { path: "case.trace.json", bytes: 20, sha256: "a".repeat(64) };
  expect(validateEvidence(candidate, baseline(), { ...budget, rawTraceRequired: true }).ok).toBe(false);
});

test.each(["probe", "adapter"])("every %s cadence run must contribute a nonempty frame window", (kind) => {
  const candidate = evidence(8);
  candidate.results[0].metricType = "frame_time";
  const cadenceBudget = { ...budget, metricTypes: { [id]: "frame_time" } };
  if (kind === "adapter") {
    candidate.results[0].samples = [];
    candidate.results[0].adapterRuns = Array.from({ length: 10 }, () => ({
      status: "complete",
      observations: [{ status: "painted", latencyMs: 12, inputAt: 10, targetPaintAt: 22, raw: {} }],
      frameGaps: [8],
      longTasks: [],
      reactCommits: 1,
      unsupportedReasons: {},
    }));
  }
  expect(validateEvidence(candidate, baseline(8), cadenceBudget).ok).toBe(true);
  const runs = kind === "adapter" ? candidate.results[0].adapterRuns : candidate.results[0].samples;
  runs.slice(0, 9).forEach((run: any) => {
    run.frameGaps = [];
  });
  expect(validateEvidence(candidate, baseline(8), cadenceBudget).ok).toBe(false);
});
