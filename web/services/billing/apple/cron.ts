// The Apple billing cron (`GET /api/cron/apple-notifications`): retry
// unfinished notifications, re-check renewals, sweep lapses, then backfill
// lost notifications until the time budget runs out.

import { appleServerApiRequired, missingAppleServerApiEnv } from "./config";
import { backfillAppleNotifications, type AppleHistoryResult } from "./history";
import { withProductionAccess, type AppleProductionApiAccess } from "./productionAccess";
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
  /**
   * Production App Store Server API access per bundle, for the bundles this
   * run asked Production about. `locked_until_release` (Production 401, the
   * Sandbox accepts the key) is expected until the app's first App Store
   * release and is not a failure; `unauthorized` (both refuse) is.
   */
  readonly productionApi: Readonly<Record<string, AppleProductionApiAccess>>;
};

/** The backfill stops requesting pages this long after the cron starts (maxDuration is 300 s). */
const BACKFILL_BUDGET_MS = 200_000;

/**
 * Runs every step even when one fails, then reports `ok: false` for a
 * failed retry, a failed lapse re-derive, a failed history read, a key that
 * both App Store environments refuse, or a production deployment without the
 * App Store Server API key.
 */
export async function runAppleIapCron(
  dependencies: AppleIapDependencies = defaultAppleIapDependencies(),
  options: { readonly startedAtMs?: number } = {},
): Promise<AppleIapCronResult> {
  // One tracker for the run, so Production is asked once per bundle.
  const deps = withProductionAccess(dependencies);
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
  const productionApi = deps.productionAccess?.snapshot() ?? {};
  const ok = retry.notifications.failed === 0 &&
    retry.lapsedFailures === 0 &&
    history.failures === 0 &&
    !Object.values(productionApi).includes("unauthorized") &&
    !missingInProduction;
  return {
    ok,
    ...retry,
    serverApi: { configured, missingInProduction, missingEnv },
    history,
    productionApi,
  };
}
