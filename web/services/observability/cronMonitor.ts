import { after } from "next/server";

import vercelConfig from "../../vercel.json";
import { reportError, scrubErrorForLog, type ReportErrorLevel } from "./report";

/**
 * Sentry cron monitoring for Vercel Cron routes. Vercel retries nothing and
 * a cron that fails, hangs, or stops being invoked used to leave only a
 * console line. Each monitored run sends an `in_progress` check-in and then
 * `ok` or `error` (a thrown error or a 5xx response), and Sentry raises an
 * issue for failed and missed runs. The schedule comes from vercel.json, so
 * the monitor cannot drift from the deployed cron.
 */

type CronSchedule = { readonly path: string; readonly schedule: string };

type SentryCheckInApi = Pick<typeof import("@sentry/nextjs"), "captureCheckIn" | "flush">;

const EVERY_MINUTE = "* * * * *";
/** Fluid compute caps a function at 800 s; a run still in progress after this is hung. */
const MAX_RUNTIME_MINUTES = 15;

/** Sentry upsert config for one cron, or undefined when vercel.json does not schedule it. */
export function cronMonitorConfig(cron: string) {
  const crons = (vercelConfig as { crons?: readonly CronSchedule[] }).crons ?? [];
  const schedule = crons.find((entry) => entry.path === `/api/cron/${cron}`)?.schedule;
  if (!schedule) return undefined;
  const everyMinute = schedule === EVERY_MINUTE;
  return {
    schedule: { type: "crontab" as const, value: schedule },
    timezone: "Etc/UTC",
    checkinMargin: 5,
    maxRuntime: MAX_RUNTIME_MINUTES,
    // A minute job gets three tries before Sentry opens an issue, so one
    // transient provider or database blip does not page anyone.
    failureIssueThreshold: everyMinute ? 3 : 1,
    recoveryThreshold: 1,
  };
}

/**
 * A cron body may override the check-in status its response implies, for a
 * deliberate non-failure such as a job that is intentionally unconfigured in
 * this deployment but still answers 5xx to its HTTP caller.
 */
export type MonitoredCronResult = {
  readonly response: Response;
  readonly checkInStatus: "ok" | "error";
};

/**
 * Run an authorized cron body under a Sentry cron monitor named after the
 * cron. Call it after authorization so an unauthenticated probe never checks
 * in. Without SENTRY_DSN the body runs unmonitored. A thrown error or a 5xx
 * response checks in `error` unless the body returns an explicit status.
 */
export async function runMonitoredCron(
  cron: string,
  run: () => Promise<Response | MonitoredCronResult>,
): Promise<Response> {
  const Sentry = await loadSentry();
  if (!Sentry) return responseOf(await run());
  const monitorConfig = cronMonitorConfig(cron);
  const startedAt = performance.now();
  const checkInId = safeCheckIn(() =>
    Sentry.captureCheckIn({ monitorSlug: cron, status: "in_progress" }, monitorConfig));
  let status: "ok" | "error" = "error";
  try {
    const result = await run();
    const response = responseOf(result);
    status = result instanceof Response
      ? (response.status >= 500 ? "error" : "ok")
      : result.checkInStatus;
    return response;
  } finally {
    const duration = (performance.now() - startedAt) / 1000;
    safeCheckIn(() =>
      checkInId
        ? Sentry.captureCheckIn({ monitorSlug: cron, status, checkInId, duration }, monitorConfig)
        : Sentry.captureCheckIn({ monitorSlug: cron, status }, monitorConfig));
    flushAfterResponse(Sentry);
  }
}

export type CronFailureOptions = {
  /** Defaults to `error`. */
  readonly level?: ReportErrorLevel;
  /** Distinguishes failure kinds within one cron (`run`, `partial`, `tunnel_reap`). */
  readonly stage?: string;
  /** Injected clock for the per-instance report throttle. */
  readonly now?: number;
};

/** One Sentry event per cron, stage and instance in this window; the monitor still records every run. */
const FAILURE_REPORT_INTERVAL_MS = 10 * 60_000;
const lastFailureReport = new Map<string, number>();

/**
 * Report a cron failure through reportError (Sentry issue grouped per cron
 * and stage, scrubbed log line). A minute cron that keeps failing would bill
 * one Sentry event per run, so repeats inside the window only log.
 */
export function reportCronFailure(
  cron: string,
  error: unknown,
  context: Record<string, unknown> = {},
  options: CronFailureOptions = {},
): void {
  const stage = options.stage ?? "run";
  const level = options.level ?? "error";
  const key = `${cron}:${stage}`;
  const now = options.now ?? Date.now();
  const last = lastFailureReport.get(key);
  if (last !== undefined && now - last < FAILURE_REPORT_INTERVAL_MS) {
    const log = level === "error" ? console.error : console.warn;
    log("cmux.cron.failure", { cron, stage, sentry: "throttled" }, scrubErrorForLog(error));
    return;
  }
  lastFailureReport.set(key, now);
  reportError(
    error,
    { subsystem: "cron", cron, stage, ...context },
    { level, fingerprint: ["cmux-cron", cron, stage], tags: { cron, "cron.stage": stage } },
  );
}

/** Test seam: forget throttle state between cases. */
export function resetCronFailureReportsForTesting(): void {
  lastFailureReport.clear();
}

function responseOf(result: Response | MonitoredCronResult): Response {
  return result instanceof Response ? result : result.response;
}

async function loadSentry(): Promise<SentryCheckInApi | undefined> {
  if (!process.env.SENTRY_DSN?.trim()) return undefined;
  try {
    return await import("@sentry/nextjs");
  } catch {
    return undefined;
  }
}

function safeCheckIn(send: () => string): string | undefined {
  try {
    return send();
  } catch {
    // Monitoring must never change the cron's outcome.
    return undefined;
  }
}

function flushAfterResponse(Sentry: SentryCheckInApi): void {
  const flush = () => Sentry.flush(2_000).then(() => undefined, () => undefined);
  try {
    after(flush);
  } catch {
    void flush();
  }
}
