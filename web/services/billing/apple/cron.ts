// The Apple billing cron (`GET /api/cron/apple-notifications`): retry
// unfinished notifications, re-check renewals, sweep lapses, then backfill
// lost notifications until the time budget runs out.

import { appleServerApiRequired, missingAppleServerApiEnv } from "./config";
import { backfillAppleNotifications, type AppleHistoryResult } from "./history";
import { defaultAppleIapDependencies, retryAppleNotifications, type AppleIapDependencies, type AppleRetryResult } from "./service";

export type AppleIapCronResult = AppleRetryResult & {
  readonly ok: boolean;
  readonly serverApi: {
    readonly configured: boolean;
    /** Production deployments must have the key; true means it is missing there. */
    readonly missingInProduction: boolean;
    /** Names of the missing env values (never their contents). */
    readonly missingEnv: readonly string[];
  };
  readonly history: AppleHistoryResult;
};

/**
 * Runs every step even when one fails, then reports `ok: false` for a
 * failed retry, a failed lapse re-derive, a failed history read, or a
 * production deployment without the App Store Server API key.
 */
/** The backfill stops requesting pages this long after the cron starts (maxDuration is 300 s). */
const BACKFILL_BUDGET_MS = 200_000;

export async function runAppleIapCron(
  deps: AppleIapDependencies = defaultAppleIapDependencies(),
  options: { readonly startedAtMs?: number } = {},
): Promise<AppleIapCronResult> {
  const startedAtMs = options.startedAtMs ?? Date.now();
  const env = deps.env ?? process.env;
  const configured = deps.serverApi !== null;
  const missingEnv = configured ? [] : missingAppleServerApiEnv(env);
  const missingInProduction = !configured && appleServerApiRequired(env);
  if (!configured) {
    const log = missingInProduction ? console.error : console.warn;
    log("apple_iap.server_api_not_configured", {
      metric: "apple_iap.server_api_not_configured",
      missingEnv,
      production: missingInProduction,
    });
  }
  // The steps that keep paying users' access run first; the renewal re-check
  // and the sweep ask Apple directly, so they do not wait on the backfill.
  // The backfill gets whatever time is left.
  const retry = await retryAppleNotifications({}, deps);
  const history = await backfillAppleNotifications(deps, { deadlineMs: startedAtMs + BACKFILL_BUDGET_MS });
  const ok = retry.notifications.failed === 0 &&
    retry.lapsedFailures === 0 &&
    history.failures === 0 &&
    !missingInProduction;
  return {
    ok,
    ...retry,
    serverApi: { configured, missingInProduction, missingEnv },
    history,
  };
}
