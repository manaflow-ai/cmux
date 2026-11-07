// The CI dashboard's model (Leo, 2026-11-07, of a page with ~25 checks in one flat list): a
// matrix's shards are one row, rows go failing, running, queued, then passed, and the summary's
// tally, share done and ETA come from the jobs.
import { expect, test } from "bun:test";
import { dashboardBuckets, dashboardRows, dashboardSummary, duration, elapsed, failedRuns } from "./checksModel";
import { mockChecks } from "./mockProvider";
import type { DashboardJob } from "./types";

const NOW = Date.parse("2026-11-05T03:00:00Z");

test("a matrix's shards are one row, in its first shard's place, with the worst state", () => {
  const rows = dashboardRows(mockChecks.jobs);
  const health = rows.find((row) => row.name === "health");
  expect(health?.matrix).toBe(true);
  expect(health?.jobs.length).toBe(8);
  expect(health?.state).toBe("failed");
  expect(rows.map((row) => row.name)).toEqual([
    "resolve head and base",
    "portable light placement",
    "test",
    "journey",
    "health",
    "web tests",
    "lint",
    "risk evidence",
  ]);
  // A lone "name (x)" is not a matrix.
  const single: DashboardJob = {
    id: 1,
    name: "build (macOS)",
    workflow: "w",
    state: "passed",
    startedAt: "",
    completedAt: "",
  };
  expect(dashboardRows([single])[0]).toMatchObject({ name: "build (macOS)", matrix: false });
});

test("rows go failing, running, queued, then passed", () => {
  const buckets = dashboardBuckets(dashboardRows(mockChecks.jobs));
  expect(buckets.failed.map((row) => row.name)).toEqual(["test", "health"]);
  expect(buckets.running.map((row) => row.name)).toEqual(["journey"]);
  expect(buckets.queued.map((row) => row.name)).toEqual(["web tests"]);
  expect(buckets.passed.length).toBe(4);
});

test("the summary counts jobs, the share done, and the ETA from the base's durations", () => {
  const summary = dashboardSummary(mockChecks.jobs, NOW);
  expect(summary).toMatchObject({ passed: 9, failed: 2, running: 3, queued: 1, total: 15 });
  expect(summary.progress).toBeCloseTo(11 / 15);
  // journey: 840 s expected, 480 s in → 360 s; the health shards: 600 s, 600 s in → 0; web tests queued: 420 s.
  expect(summary.eta).toBe(420);
  expect(dashboardSummary([], NOW)).toMatchObject({ total: 0, progress: 1, eta: null });
});

test("elapsed, durations and the runs Re-run failed names", () => {
  expect(elapsed(mockChecks.jobs[3]!, NOW)).toBe(480);
  expect(elapsed(mockChecks.jobs[2]!, NOW)).toBe(570);
  expect(duration(570, "en")).toBe("9m 30s");
  expect(duration(3720, "en")).toBe("1h 2m");
  expect(duration(12, "en")).toBe("12s");
  expect(failedRuns(mockChecks.jobs)).toEqual([9001]);
});
