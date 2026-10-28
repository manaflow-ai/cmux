// cmux-perf-result/v1 from the webviews benches and perf tests (p12-perf-process-219).
//
// When PERF_RESULT_DIR is set, recordPerfResults pipes one bench's series to
// scripts/perf-lab/bench_results.py, which fills the build, host and run blocks from the lab's
// PERF_LAB_* variables and writes them through scripts/perf-lab/perf_result.py, the lab's one
// result writer and validator. Unset, it writes nothing, so a bench run by hand behaves as before.
// Imported by bun (TypeScript benches and tests) and by node (the .mjs benches).
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

export const BENCH_RESULTS_PY = fileURLToPath(new URL("../../scripts/perf-lab/bench_results.py", import.meta.url));

// One run per bench process: the results of several record calls in one process are one lab run.
// A story that runs several processes sets PERF_LAB_RUN_ID and PERF_LAB_RUN_STARTED_AT instead.
const PROCESS_RUN = { id: randomUUID().replaceAll("-", ""), started_at: new Date().toISOString() };

/**
 * The folder result-v1 goes to, or undefined when the run records nothing.
 * @param {Record<string, string | undefined>} [env]
 * @returns {string | undefined}
 */
export function perfResultDir(env = process.env) {
  const dir = env.PERF_RESULT_DIR?.trim();
  return dir ? dir : undefined;
}

/**
 * One series of raw samples, or undefined when none of `values` is a finite number (a probe that
 * never fired), so the caller can list optional series without a branch each.
 * @param {string} metric a result-v1 name, `web.<bench>.<what>`
 * @param {string} unit a result-v1 unit (ms, count, bytes, ...)
 * @param {ReadonlyArray<unknown>} values
 * @param {"lower" | "higher"} [better]
 * @returns {{ metric: string, unit: string, better: "lower" | "higher", samples: number[] } | undefined}
 */
export function perfSeries(metric, unit, values, better = "lower") {
  const samples = values.filter((value) => typeof value === "number" && Number.isFinite(value));
  return samples.length > 0 ? { metric, unit, better, samples } : undefined;
}

/**
 * Writes `series` as one result-v1 file when PERF_RESULT_DIR is set and returns its path; returns
 * undefined (and starts nothing) when it is unset. Throws when nothing is left to record or the
 * writer refuses, so a lab run never passes with its results missing.
 * @param {{ story: string, engine: "chromium" | "webkit" | "none", series: ReadonlyArray<ReturnType<typeof perfSeries>> }} bench
 *   `story` is the bench's own story id; the lab's PERF_LAB_STORY replaces it.
 * @param {{ env?: Record<string, string | undefined>, spawn?: typeof spawnSync }} [options]
 * @returns {string | undefined}
 */
export function recordPerfResults({ story, engine, series }, { env = process.env, spawn = spawnSync } = {}) {
  if (perfResultDir(env) === undefined) return undefined;
  const results = series.filter((entry) => entry !== undefined);
  if (results.length === 0) throw new Error(`perf-result: ${story} has no samples to record`);
  const done = spawn("python3", ["-I", BENCH_RESULTS_PY], {
    env,
    input: JSON.stringify({ story, engine, run: PROCESS_RUN, results }),
    encoding: "utf8",
  });
  if (done.error) throw new Error(`perf-result: cannot run ${BENCH_RESULTS_PY}: ${done.error.message}`);
  if (done.status !== 0) {
    throw new Error(`perf-result: ${story} was not recorded (exit ${done.status}): ${String(done.stderr).trim()}`);
  }
  return String(done.stdout).trim();
}
