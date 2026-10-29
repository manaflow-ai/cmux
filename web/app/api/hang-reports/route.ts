import { checkRateLimit as checkVercelRateLimit } from "@vercel/firewall";
import * as Cause from "effect/Cause";
import type * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Option from "effect/Option";

import { readBoundedJsonObject } from "../../../services/apns/routePolicy";
import { runWithHangReportsDatabase } from "../../../services/hangReports/database";
import {
  errorTag,
  type HangReportError,
  type HangReportFailureContext,
  type HangReportStorageUnavailable,
} from "../../../services/hangReports/errors";
import { ingestHangReport } from "../../../services/hangReports/ingest";
import type { HangReportsRepository } from "../../../services/hangReports/repository";
import { HANG_REPORT_MAX_BYTES } from "../../../services/hangReports/wireSchema";
import { reportError } from "../../../services/observability/report";
import { reportMissingRateLimitRule } from "../../../services/rateLimitObservability";
import { setSpanAttributes, withApiRouteSpan } from "../../../services/telemetry";
import { jsonResponse } from "../../../services/vms/routeHelpers";

/*
 * Anonymous opt-in hang reports from cmux NEXT Nightly (schema 2; schema 1 refused).
 *
 * Privacy: this handler never reads a client address header
 * (x-forwarded-for, x-real-ip, or similar) or the user agent, never logs or
 * reports the body, and puts only the route, status and counts in its span.
 * A failure is reported as a fixed context (operation, error tag, SQLSTATE),
 * never as the underlying error, whose message can carry query parameters.
 */

const ROUTE = "/api/hang-reports";
const NO_STORE = { "cache-control": "no-store" } as const;

type IngestResult = Effect.Effect.Success<ReturnType<typeof ingestHangReport>>;

export type HangReportsRouteDependencies = {
  readonly checkRateLimit: typeof checkVercelRateLimit;
  readonly reportMissingRateLimitRule: typeof reportMissingRateLimitRule;
  readonly run: (
    program: Effect.Effect<IngestResult, HangReportError, HangReportsRepository>,
  ) => Promise<Exit.Exit<IngestResult, HangReportError | HangReportStorageUnavailable>>;
  readonly reportFailure: (context: HangReportFailureContext) => void;
  readonly now: () => Date;
};

const defaultDependencies: HangReportsRouteDependencies = {
  checkRateLimit: checkVercelRateLimit,
  reportMissingRateLimitRule,
  run: runWithHangReportsDatabase,
  reportFailure: (context) => reportError(
    new Error(`hang report ${context.operation} failed: ${context.tag}`),
    { subsystem: "hang-reports", ...context },
    { fingerprint: ["hang-reports", context.operation, context.tag] },
  ),
  now: () => new Date(),
};

export const POST = makeHangReportsHandler();

export function makeHangReportsHandler(dependencies: HangReportsRouteDependencies = defaultDependencies) {
  return async function POST(request: Request): Promise<Response> {
    return withApiRouteSpan(request, ROUTE, { "cmux.subsystem": "hang-reports" }, async (span) => {
      const limited = await enforceRateLimit(request, dependencies);
      if (limited) return limited;

      const body = await readBoundedJsonObject(request, HANG_REPORT_MAX_BYTES);
      if (!body.ok) {
        return body.error === "request_too_large"
          ? jsonResponse({ error: "request_too_large" }, 413, NO_STORE)
          : jsonResponse({ error: "invalid_json" }, 400, NO_STORE);
      }

      const exit = await dependencies.run(ingestHangReport(body.value, dependencies.now()));
      if (Exit.isSuccess(exit)) {
        setSpanAttributes(span, {
          "cmux.hang_reports.outcome": exit.value.outcome,
          "cmux.hang_reports.hang_count": exit.value.hangCount,
        });
        return new Response(null, { status: 204, headers: NO_STORE });
      }
      return failureResponse(exit.cause, dependencies);
    });
  };
}

function failureResponse(
  cause: Cause.Cause<HangReportError | HangReportStorageUnavailable>,
  dependencies: HangReportsRouteDependencies,
): Response {
  const failure = Cause.failureOption(cause);
  if (Option.isNone(failure)) {
    // A defect is a server bug. Report only its tag: a thrown error's message
    // can carry the body or query parameters.
    dependencies.reportFailure({ operation: "defect", tag: errorTag(Cause.squash(cause)), sqlstate: null });
    return jsonResponse({ error: "internal_error" }, 500, NO_STORE);
  }
  const error = failure.value;
  switch (error._tag) {
    case "HangReportInvalid":
      return jsonResponse({ error: "invalid_report", reason: error.reason }, 400, NO_STORE);
    case "HangReportDailyCapExceeded":
      return jsonResponse(
        { error: "rate_limited" },
        429,
        { ...NO_STORE, "retry-after": String(error.retryAfterSeconds) },
      );
    case "HangReportStorageUnavailable":
      dependencies.reportFailure({ operation: error.operation, tag: error.causeTag, sqlstate: error.sqlstate });
      return jsonResponse({ error: "storage_unavailable" }, 503, NO_STORE);
  }
}

async function enforceRateLimit(
  request: Request,
  dependencies: HangReportsRouteDependencies,
): Promise<Response | null> {
  if (process.env.VERCEL !== "1") return null;
  const ruleId = process.env.CMUX_HANG_REPORTS_RATE_LIMIT_ID?.trim();
  if (!ruleId) {
    // Fail closed: without the edge rule nothing bounds a flood of fresh
    // install ids. The client keeps the report and retries later.
    dependencies.reportMissingRateLimitRule({ route: ROUTE, reason: "unset" });
    return jsonResponse({ error: "rate_limit_unavailable" }, 503, NO_STORE);
  }
  try {
    const { error, rateLimited } = await dependencies.checkRateLimit(ruleId, { request });
    if (rateLimited || error === "blocked") {
      return jsonResponse({ error: "rate_limited" }, 429, { ...NO_STORE, "retry-after": "60" });
    }
    if (error === "not-found") {
      dependencies.reportMissingRateLimitRule({ route: ROUTE, reason: "not-found" });
      return jsonResponse({ error: "rate_limit_unavailable" }, 503, NO_STORE);
    }
    if (error) return jsonResponse({ error: "rate_limit_unavailable" }, 503, NO_STORE);
  } catch {
    return jsonResponse({ error: "rate_limit_unavailable" }, 503, NO_STORE);
  }
  return null;
}
