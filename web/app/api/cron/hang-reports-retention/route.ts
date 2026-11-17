import * as Cause from "effect/Cause";
import type * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Option from "effect/Option";

import { authorizeCronRequest } from "../../../../services/cronAuth";
import { runWithHangReportsDatabase } from "../../../../services/hangReports/database";
import {
  errorTag,
  type HangReportFailureContext,
  type HangReportStorageUnavailable,
} from "../../../../services/hangReports/errors";
import type { HangReportsRepository } from "../../../../services/hangReports/repository";
import { pruneExpiredHangReports, type RetentionResult } from "../../../../services/hangReports/retention";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

const CRON = "hang-reports-retention";

export type HangReportsRetentionDependencies = {
  readonly run: (
    program: Effect.Effect<RetentionResult, HangReportStorageUnavailable, HangReportsRepository>,
  ) => Promise<Exit.Exit<RetentionResult, HangReportStorageUnavailable>>;
  readonly now: () => Date;
  readonly reportFailure: (context: HangReportFailureContext) => void;
};

const defaultDependencies: HangReportsRetentionDependencies = {
  run: runWithHangReportsDatabase,
  now: () => new Date(),
  reportFailure: (context) => reportCronFailure(
    CRON,
    new Error(`hang report ${context.operation} failed: ${context.tag}`),
    { ...context },
  ),
};

export const GET = makeHangReportsRetentionHandler();

export function makeHangReportsRetentionHandler(
  dependencies: HangReportsRetentionDependencies = defaultDependencies,
) {
  return async function GET(request: Request): Promise<Response> {
    const auth = authorizeCronRequest(request);
    if (!auth.ok && auth.reason === "cron_secret_missing") {
      return jsonResponse({ error: "service_unavailable" }, 503);
    }
    if (!auth.ok) return jsonResponse({ error: "unauthorized" }, 401);
    return runMonitoredCron(CRON, async () => {
      const exit = await dependencies.run(pruneExpiredHangReports(dependencies.now()));
      if (Exit.isSuccess(exit)) return jsonResponse({ ok: true, ...exit.value });
      // Report a fixed context, never the Cause: an error message there can
      // carry query parameters.
      const failure = Cause.failureOption(exit.cause);
      const context = Option.isSome(failure)
        ? { operation: failure.value.operation, tag: failure.value.causeTag, sqlstate: failure.value.sqlstate }
        : { operation: "defect", tag: errorTag(Cause.squash(exit.cause)), sqlstate: null };
      dependencies.reportFailure(context);
      return jsonResponse({ error: "hang_report_retention_failed" }, 500);
    });
  };
}
