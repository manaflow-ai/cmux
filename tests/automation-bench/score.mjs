// Scoreboard for the automation bench (plans/cmux-next/automation-bench.md).
// Input: result rows (one per task run). Output: one summary per driver and
// domain. Live-web rows are scored apart because they are flaky by design.

export const FAILURE_CATEGORIES = Object.freeze([
  "nav", "ref_stale", "wait", "input", "policy_block", "focus_stolen", "not_landed", "timeout",
]);

export function percentile(values, p) {
  throw new Error("not implemented");
}

export function validateRow(row) {
  throw new Error("not implemented");
}

export function summarize(rows) {
  throw new Error("not implemented");
}
