import type * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";

import { authorizeCronRequest } from "../../../../services/cronAuth";
import { runWithHangReportsDatabase } from "../../../../services/hangReports/database";
import type { HangReportStorageUnavailable } from "../../../../services/hangReports/errors";
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
};

const defaultDependencies: HangReportsRetentionDependencies = {
  run: runWithHangReportsDatabase,
  now: () => new Date(),
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
      reportCronFailure(CRON, exit.cause);
      return jsonResponse({ error: "hang_report_retention_failed" }, 500);
    });
  };
}
