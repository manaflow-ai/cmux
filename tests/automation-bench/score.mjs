// Scoreboard for the automation bench (plans/cmux-next/automation-bench.md).
// Input: result rows (one per task run). Output: one summary per driver and
// domain. Live-web rows are scored apart because they are flaky by design.

export const FAILURE_CATEGORIES = Object.freeze([
  "nav", "ref_stale", "wait", "input", "policy_block", "focus_stolen", "not_landed", "timeout",
]);

const DOMAINS = new Set(["browser", "desktop"]);
const LEVELS = new Set(["primitive", "task"]);

/** Nearest-rank percentile; null for an empty list. */
export function percentile(values, p) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(sorted.length, Math.max(1, rank)) - 1];
}

export function validateRow(row) {
  if (!DOMAINS.has(row.domain)) throw new Error(`row ${row.task_id}: unknown domain ${row.domain}`);
  if (!LEVELS.has(row.level)) throw new Error(`row ${row.task_id}: unknown level ${row.level}`);
  if (row.ok && row.failure !== undefined) {
    throw new Error(`row ${row.task_id}: a passing row has no failure category`);
  }
  if (!row.ok && !FAILURE_CATEGORIES.includes(row.failure)) {
    throw new Error(`row ${row.task_id}: a failing row needs a failure category, got ${row.failure}`);
  }
}

function median(values) {
  return percentile(values, 50);
}

export function summarize(rows) {
  rows.forEach(validateRow);
  const groups = new Map();
  for (const row of rows) {
    const key = `${row.driver}\u0000${row.domain}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }
  const summaries = [];
  for (const group of groups.values()) {
    const { driver, domain } = group[0];
    const scored = group.filter((row) => !row.live);
    const live = group.filter((row) => row.live);
    const failures = {};
    const latencies = {};
    for (const row of scored) {
      if (!row.ok) failures[row.failure] = (failures[row.failure] ?? 0) + 1;
      for (const [primitive, values] of Object.entries(row.latencies ?? {})) {
        (latencies[primitive] ??= []).push(...values);
      }
    }
    const walls = scored.map((row) => row.wall_ms);
    summaries.push({
      driver,
      domain,
      n: scored.length,
      success_rate: scored.length ? scored.filter((row) => row.ok).length / scored.length : null,
      focus_preserved_rate: scored.length
        ? scored.filter((row) => row.focus_preserved).length / scored.length
        : null,
      median_steps: median(scored.map((row) => row.steps)),
      wall_ms: { p50: percentile(walls, 50), p95: percentile(walls, 95) },
      failures,
      latency_ms: Object.fromEntries(
        Object.entries(latencies)
          .sort(([a], [b]) => a.localeCompare(b))
          .map(([primitive, values]) => [
            primitive,
            { n: values.length, p50: percentile(values, 50), p95: percentile(values, 95) },
          ]),
      ),
      live: { n: live.length, ok: live.filter((row) => row.ok).length },
    });
  }
  return summaries.sort((a, b) => `${a.driver}/${a.domain}`.localeCompare(`${b.driver}/${b.domain}`));
}
