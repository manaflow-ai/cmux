// The CI dashboard's model (Leo, 2026-11-07: "here's your big dashboard"): jobs grouped into rows,
// a matrix's shards (`health (0)` … `health (7)`) one row with a pip each; rows in the order a
// person acts on them (failing, running, queued, then passed folded to one line); the tally, the
// share done, and an ETA from how long each job took at the base branch's tip.
import type { DashboardJob } from "./types";

export type JobState = DashboardJob["state"];

/** One dashboard row: a job, or a matrix's shards. */
export interface DashboardRow {
  key: string;
  name: string;
  workflow: string;
  /** The worst of its jobs' states. */
  state: JobState;
  jobs: DashboardJob[];
  /** More than one shard of one matrix. */
  matrix: boolean;
}

const WORST: Record<JobState, number> = { failed: 0, running: 1, queued: 2, passed: 3, skipped: 4 };
const MATRIX = /^(.*\S)\s*\(([^()]*)\)$/;

/** `jobs` as rows: a matrix's shards (same workflow, `name (x)`) together, in their first job's place. */
export function dashboardRows(jobs: readonly DashboardJob[]): DashboardRow[] {
  const byKey = new Map<string, DashboardRow>();
  const counts = new Map<string, number>();
  const base = (job: DashboardJob) => MATRIX.exec(job.name)?.[1];
  for (const job of jobs) {
    const name = base(job);
    if (name) counts.set(`${job.workflow}\0${name}`, (counts.get(`${job.workflow}\0${name}`) ?? 0) + 1);
  }
  for (const job of jobs) {
    const name = base(job);
    const grouped = name !== undefined && (counts.get(`${job.workflow}\0${name}`) ?? 0) > 1;
    const key = grouped ? `${job.workflow}\0${name}` : `${job.workflow}\0${job.name}\0${job.id}`;
    const row = byKey.get(key);
    if (row) {
      row.jobs.push(job);
      if (WORST[job.state] < WORST[row.state]) row.state = job.state;
    } else {
      byKey.set(key, {
        key,
        name: grouped ? name! : job.name,
        workflow: job.workflow,
        state: job.state,
        jobs: [job],
        matrix: grouped,
      });
    }
  }
  return [...byKey.values()];
}

/** Rows by what a person does with them: failing, running, queued, done. */
export function dashboardBuckets(rows: readonly DashboardRow[]) {
  return {
    failed: rows.filter((row) => row.state === "failed"),
    running: rows.filter((row) => row.state === "running"),
    queued: rows.filter((row) => row.state === "queued"),
    passed: rows.filter((row) => row.state === "passed" || row.state === "skipped"),
  };
}

export interface DashboardSummary {
  passed: number;
  failed: number;
  running: number;
  queued: number;
  total: number;
  /** Jobs done, 0 to 1. */
  progress: number;
  /** Seconds until the last running or queued job should end, from the base's durations; null when unknown. */
  eta: number | null;
}

/** The tally over jobs (not rows), the share done, and the ETA at `now`. */
export function dashboardSummary(jobs: readonly DashboardJob[], now: number): DashboardSummary {
  const count = (state: JobState) => jobs.filter((job) => job.state === state).length;
  const passed = count("passed") + count("skipped");
  const failed = count("failed");
  const running = count("running");
  const queued = count("queued");
  const total = jobs.length;
  let eta: number | null = null;
  for (const job of jobs) {
    if ((job.state !== "running" && job.state !== "queued") || job.expected == null) continue;
    const left = job.expected - (job.state === "running" ? elapsed(job, now) : 0);
    eta = Math.max(eta ?? 0, left, 0);
  }
  return { passed, failed, running, queued, total, progress: total ? (passed + failed) / total : 1, eta };
}

/** Seconds since `job` started (to its end when it ended), 0 when it has not. */
export function elapsed(job: DashboardJob, now: number): number {
  const start = Date.parse(job.startedAt);
  if (!Number.isFinite(start)) return 0;
  const end = job.completedAt ? Date.parse(job.completedAt) : now;
  return Math.max(0, ((Number.isFinite(end) ? end : now) - start) / 1000);
}

/** `seconds` as `1h 4m`, `4m 12s` or `12s`, each unit in `locale`'s narrow form. */
export function duration(seconds: number, locale?: string): string {
  const whole = Math.max(0, Math.round(seconds));
  const hours = Math.floor(whole / 3600);
  const minutes = Math.floor((whole % 3600) / 60);
  const unit = (value: number, name: "hour" | "minute" | "second") =>
    new Intl.NumberFormat(locale, { style: "unit", unit: name, unitDisplay: "narrow" }).format(value);
  if (hours) return `${unit(hours, "hour")} ${unit(minutes, "minute")}`;
  if (minutes) return `${unit(minutes, "minute")} ${unit(whole % 60, "second")}`;
  return unit(whole, "second");
}

/** The Actions runs with a failed job: what Re-run failed reruns. */
export function failedRuns(jobs: readonly DashboardJob[]): number[] {
  return [...new Set(jobs.filter((job) => job.state === "failed" && job.run != null).map((job) => job.run!))];
}
