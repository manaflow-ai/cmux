import * as Effect from "effect/Effect";

import { catalogIngest, droppedNames, filterToCatalog, hasKeyRecord } from "./catalogFilter";
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

const BLANK_PROFILE = { version: "0", build: "0" } as const;

/**
 * The version fields are already digits and dots only. A four-part version
 * ("1.2.3.4") is legal and would read as an IPv4 shape, so the scan sees
 * them as "0"; every other string is scanned as sent.
 */
function withoutVersions(report: HangReport): unknown {
  const blanked = { ...report, app: { ...report.app, ...BLANK_PROFILE }, os: { version: "0" } };
  if (report.schema !== 3) return blanked;
  return {
    ...blanked,
    launches: report.launches.map((launch) => ({
      ...launch,
      app: { ...launch.app, ...BLANK_PROFILE },
      os: { version: "0" },
    })),
  };
}

/** Decode, bound-check and privacy-scan an untrusted body. */
export function validateHangReport(body: unknown, now: Date): Effect.Effect<HangReport, HangReportInvalid> {
  return Effect.gen(function* () {
    const report = decodeHangReport(body);
    if (!report) return yield* Effect.fail(new HangReportInvalid({ reason: "schema" }));
    if (!dayWithinWindow(report.day, now)) {
      return yield* Effect.fail(new HangReportInvalid({ reason: "day_out_of_range" }));
    }
    if (hasKeyRecord(report)) return yield* Effect.fail(new HangReportInvalid({ reason: "blackbox_key_record" }));
    const leak = scanForLeaks(withoutVersions(report));
    if (leak) return yield* Effect.fail(new HangReportInvalid({ reason: LEAK_REASONS[leak] }));
    return report;
  });
}

/** A stored row and how many names the catalog filter dropped to build it. */
export type HangReportRowResult = { readonly row: HangReportRow; readonly droppedNames: number };

/**
 * The row stored for a validated report received at `now`. A schema 3
 * payload keeps only catalog names, plus an `ingest` record with the server
 * catalog version and the drop counts (jsonb, so no column or migration).
 */
export function hangReportRow(validated: HangReport, now: Date): HangReportRowResult {
  const { report, drops } = filterToCatalog(validated);
  const payload = report.schema === 3 ? { ...report, ingest: catalogIngest(drops) } : report;
  return {
    row: {
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
      payload: payload as unknown as Record<string, unknown>,
    },
    droppedNames: droppedNames(drops),
  };
}

/**
 * The hang report ingest workflow: validate, drop names outside the
 * catalog, then store once under the per-install daily cap. A duplicate
 * `reportId` succeeds without a second row.
 */
export function ingestHangReport(body: unknown, now: Date) {
  return Effect.gen(function* () {
    const report = yield* validateHangReport(body, now);
    const { row, droppedNames } = hangReportRow(report, now);
    const repository = yield* HangReportsRepository;
    const outcome = yield* repository.insertWithinDailyCap(row, HANG_REPORTS_PER_INSTALL_PER_DAY);
    if (outcome === "capped") {
      return yield* Effect.fail(new HangReportDailyCapExceeded({ retryAfterSeconds: secondsUntilNextUtcDay(now) }));
    }
    return { outcome, schema: report.schema, hangCount: report.hangs.length, droppedNames } as const;
  }).pipe(Effect.withSpan("hang_reports.ingest"));
}

function secondsUntilNextUtcDay(now: Date): number {
  const next = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
  return Math.max(60, Math.ceil((next - now.getTime()) / 1000));
}
