import * as Effect from "effect/Effect";

import { HangReportDailyCapExceeded, HangReportInvalid, type HangReportInvalidReason } from "./errors";
import { droppedTotal, normalizeFieldData, type DroppedFieldData } from "./fieldData";
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

/** A validated report and what ingest dropped from it (schema 3 only). */
export type ValidatedHangReport = {
  readonly report: HangReport;
  readonly dropped: DroppedFieldData | null;
};

/**
 * Decode, bound-check and privacy-scan an untrusted body. Unknown histogram
 * names and stability keys are dropped and counted, not refused.
 */
export function validateHangReport(body: unknown, now: Date): Effect.Effect<ValidatedHangReport, HangReportInvalid> {
  return Effect.gen(function* () {
    const decoded = decodeHangReport(body);
    if (!decoded) return yield* Effect.fail(new HangReportInvalid({ reason: "schema" }));
    if (!dayWithinWindow(decoded.day, now)) {
      return yield* Effect.fail(new HangReportInvalid({ reason: "day_out_of_range" }));
    }
    const normalized = normalizeFieldData(decoded);
    if (!normalized.ok) return yield* Effect.fail(new HangReportInvalid({ reason: normalized.reason }));
    const leak = scanForLeaks(withoutVersions(normalized.report));
    if (leak) return yield* Effect.fail(new HangReportInvalid({ reason: LEAK_REASONS[leak] }));
    return { report: normalized.report, dropped: normalized.dropped };
  });
}

// The version fields are already digits and dots only. A four-part version
// ("1.2.3.4") is legal and would read as an IPv4 shape, so the scan sees
// them as "0"; every other string is scanned as sent.
const NEUTRAL_APP = { version: "0", build: "0" } as const;
const NEUTRAL_OS = { version: "0" } as const;

function withoutVersions(report: HangReport): unknown {
  const neutral = { ...report, app: { ...report.app, ...NEUTRAL_APP }, os: NEUTRAL_OS };
  if (report.schema !== 3) return neutral;
  return {
    ...neutral,
    sections: report.sections.map((section) => ({
      ...section,
      profile: { app: { ...section.profile.app, ...NEUTRAL_APP }, os: NEUTRAL_OS },
    })),
  };
}

/**
 * The row stored for a validated report received at `now`. A schema 3
 * payload keeps the report as normalized plus `dropped`, in the existing
 * `payload` jsonb column (no migration).
 */
export function hangReportRow({ report, dropped }: ValidatedHangReport, now: Date): HangReportRow {
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
    payload: (dropped ? { ...report, dropped } : report) as unknown as Record<string, unknown>,
  };
}

/**
 * The hang report ingest workflow: validate, then store once under the
 * per-install daily cap. A duplicate `reportId` succeeds without a second row.
 */
export function ingestHangReport(body: unknown, now: Date) {
  return Effect.gen(function* () {
    const validated = yield* validateHangReport(body, now);
    const repository = yield* HangReportsRepository;
    const outcome = yield* repository.insertWithinDailyCap(hangReportRow(validated, now), HANG_REPORTS_PER_INSTALL_PER_DAY);
    if (outcome === "capped") {
      return yield* Effect.fail(new HangReportDailyCapExceeded({ retryAfterSeconds: secondsUntilNextUtcDay(now) }));
    }
    return {
      outcome,
      schema: validated.report.schema,
      hangCount: validated.report.hangs.length,
      droppedNames: droppedTotal(validated.dropped),
    } as const;
  }).pipe(Effect.withSpan("hang_reports.ingest"));
}

function secondsUntilNextUtcDay(now: Date): number {
  const next = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
  return Math.max(60, Math.ceil((next - now.getTime()) / 1000));
}
