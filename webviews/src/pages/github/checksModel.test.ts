// The CI dashboard's model (Leo, 2026-11-07, of a page with ~25 checks in one flat list): a
// matrix's shards are one row, rows go failing, running, queued, then passed, and the summary's
// tally, share done and ETA come from the jobs.
import { expect, test } from "bun:test";
import {
  dashboardBuckets,
  dashboardRows,
  dashboardSummary,
  duration,
  elapsed,
  failedRuns,
  withRollup,
} from "./checksModel";
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

test("a finished commit status with no end time has no duration; only a running job counts to now", () => {
  // GitHub dates a commit status (cmux-next/fast-gates) only by when it was posted: it never ends.
  const status = (state: DashboardJob["state"]): DashboardJob => ({
    id: 0,
    name: "cmux-next/fast-gates",
    workflow: "",
    state,
    startedAt: "2026-11-05T02:37:03Z",
    completedAt: "",
  });
  expect(elapsed(status("failed"), NOW)).toBe(0);
  expect(elapsed(status("passed"), NOW)).toBe(0);
  expect(elapsed(status("running"), NOW)).toBe(1377);
});

test("one matrix's push run and pull_request run are separate rows", () => {
  const shard = (id: number, event: string, state: DashboardJob["state"]): DashboardJob => ({
    id,
    name: `health (${id % 2})`,
    workflow: "ci",
    event,
    state,
    startedAt: "",
    completedAt: "",
  });
  const rows = dashboardRows([
    shard(1, "push", "failed"),
    shard(2, "push", "passed"),
    shard(3, "pull_request", "passed"),
    shard(4, "pull_request", "passed"),
  ]);
  expect(rows.map((row) => [row.state, row.jobs.length])).toEqual([
    ["failed", 2],
    ["passed", 2],
  ]);
});

test("the rollup marks a failing job on the base, and fills a cut-short read's failures", () => {
  const job = (id: number, name: string, state: DashboardJob["state"]): DashboardJob => ({
    id,
    name,
    workflow: "ci",
    state,
    startedAt: "",
    completedAt: "",
  });
  const rollup = [
    { name: "lint", state: "failed", onBase: true },
    { name: "build", state: "passed", onBase: true },
    { name: "deploy", state: "failed", url: "https://github.com/x/1" },
    { name: "docs", state: "pending" },
    { name: "format", state: "passed" },
  ];
  const checks = { head: "abc", settled: true, jobs: [job(1, "lint", "failed"), job(2, "build", "passed")] };
  // Only a failing job is marked; a whole read adds nothing.
  expect(withRollup(checks, rollup).jobs.map((each) => [each.name, each.onBase ?? false])).toEqual([
    ["lint", true],
    ["build", false],
  ]);
  const cut = withRollup({ ...checks, settled: false, truncated: true }, rollup);
  expect(cut.jobs.map((each) => [each.name, each.state])).toEqual([
    ["lint", "failed"],
    ["build", "passed"],
    ["deploy", "failed"],
    ["docs", "running"],
  ]);
});

test("the rollup matches a check to its job by link, never by a shared name", () => {
  const run = (id: number) => `https://github.com/o/r/actions/runs/9/job/${id}`;
  const job = (id: number, workflow: string, state: DashboardJob["state"]): DashboardJob => ({
    id,
    name: "test",
    workflow,
    state,
    startedAt: "",
    completedAt: "",
    url: run(id),
  });
  // A passing `test` was read; a failing `test` past the read's window still shows.
  const cut = withRollup({ head: "abc", settled: false, truncated: true, jobs: [job(1, "unit", "passed")] }, [
    { name: "test", state: "passed", url: run(1) },
    { name: "test", state: "failed", url: run(2) },
  ]);
  expect(cut.jobs.map((each) => [each.name, each.state, each.url])).toEqual([
    ["test", "passed", run(1)],
    ["test", "failed", run(2)],
  ]);
  // Only the `test` that fails on the base is marked, not every failing `test`.
  const both = withRollup({ head: "abc", settled: true, jobs: [job(3, "unit", "failed"), job(4, "e2e", "failed")] }, [
    { name: "test", state: "failed", url: run(3), onBase: true },
    { name: "test", state: "failed", url: run(4) },
  ]);
  expect(both.jobs.map((each) => [each.workflow, each.onBase ?? false])).toEqual([
    ["unit", true],
    ["e2e", false],
  ]);
});
