import * as Effect from "effect/Effect";

import { HangReportDailyCapExceeded, HangReportInvalid, type HangReportInvalidReason } from "./errors";
import { scanForLeaks, type LeakReason } from "./leakScan";
import { HangReportsRepository, type HangReportRow } from "./repository";
import { dayWithinWindow, decodeHangReport, utcDay, type HangReport } from "./wireSchema";

/** Reports one install may store per server UTC day. */
export const HANG_REPORTS_PER_INSTALL_PER_DAY = 8;

const LEAK_REASONS: Record<LeakReason, HangReportInvalidReason> = {
  path: "leak_path",
  email: "leak_email",
  url: "leak_url",
  ip_address: "leak_ip_address",
  token: "leak_token",
};

/** Decode, bound-check and privacy-scan an untrusted body. */
export function validateHangReport(body: unknown, now: Date): Effect.Effect<HangReport, HangReportInvalid> {
  return Effect.gen(function* () {
    const report = decodeHangReport(body);
    if (!report) return yield* Effect.fail(new HangReportInvalid({ reason: "schema" }));
    if (!dayWithinWindow(report.day, now)) {
      return yield* Effect.fail(new HangReportInvalid({ reason: "day_out_of_range" }));
    }
    // The version fields are already digits and dots only. A four-part
    // version ("1.2.3.4") is legal and would read as an IPv4 shape, so the
    // scan sees them as "0"; every other string is scanned as sent.
    const leak = scanForLeaks({
      ...report,
      app: { ...report.app, version: "0", build: "0" },
      os: { version: "0" },
    });
    if (leak) return yield* Effect.fail(new HangReportInvalid({ reason: LEAK_REASONS[leak] }));
    return report;
  });
}

/** The row stored for a validated report received at `now`. */
export function hangReportRow(report: HangReport, now: Date): HangReportRow {
  return {
    reportId: report.reportId.toLowerCase(),
    installId: report.installId.toLowerCase(),
    receivedDay: utcDay(now),
    appVersion: report.app.version,
    appBuild: report.app.build,
    channel: report.app.channel,
    osVersion: report.os.version,
    arch: report.hardware.arch,
    chip: report.hardware.chip,
    cores: report.hardware.cores,
    memoryGb: report.hardware.memoryGB,
    counts: { ...report.counts },
    payload: report as unknown as Record<string, unknown>,
  };
}

/**
 * The hang report ingest workflow: validate, then store once under the
 * per-install daily cap. A duplicate `reportId` succeeds without a second row.
 */
export function ingestHangReport(body: unknown, now: Date) {
  return Effect.gen(function* () {
    const report = yield* validateHangReport(body, now);
    const repository = yield* HangReportsRepository;
    const outcome = yield* repository.insertWithinDailyCap(hangReportRow(report, now), HANG_REPORTS_PER_INSTALL_PER_DAY);
    if (outcome === "capped") {
      return yield* Effect.fail(new HangReportDailyCapExceeded({ retryAfterSeconds: secondsUntilNextUtcDay(now) }));
    }
    return { outcome, hangCount: report.hangs.length } as const;
  }).pipe(Effect.withSpan("hang_reports.ingest"));
}

function secondsUntilNextUtcDay(now: Date): number {
  const next = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
  return Math.max(60, Math.ceil((next - now.getTime()) / 1000));
}
