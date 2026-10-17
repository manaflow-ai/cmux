import { authorizeCronRequest } from "../../../../services/cronAuth";
import { databasePaywallExperimentLog } from "../../../../services/billing/paywall/store";
import { optimizerPostHogApi, runAllOptimizers } from "../../../../services/billing/paywall/runAll";
import { captureBillingError } from "../../../../services/errors";

export const maxDuration = 120;

/**
 * Daily paywall optimizer (services/billing/paywall/EXPERIMENTS.md). Records
 * each experiment's run, report and change log. It writes traffic splits to
 * the PostHog flags only with PAYWALL_OPTIMIZER_APPLY=1; otherwise, or when
 * the flag write fails (the key lacks write scope), it observes and proposes.
 * Without POSTHOG_PERSONAL_API_KEY it does nothing.
 */
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const api = optimizerPostHogApi(process.env);
  if (!api) return Response.json({ ok: true, skipped: "posthog_personal_api_key_missing" });
  const outcomes = await runAllOptimizers({
    api,
    log: databasePaywallExperimentLog(),
    dryRun: false,
    now: new Date(),
    actor: "optimizer-cron",
    applyAllocation: process.env.PAYWALL_OPTIMIZER_APPLY === "1",
  });
  for (const outcome of outcomes) {
    if (!outcome.ok) {
      captureBillingError(new Error(outcome.error), { operation: "paywall_optimizer", experiment: outcome.experiment });
    } else if (outcome.result.writeFailure) {
      captureBillingError(new Error(`Paywall optimizer flag write failed: ${outcome.result.writeFailure}`), {
        operation: "paywall_optimizer_flag_write", experiment: outcome.experiment,
      });
    }
  }
  const failed = outcomes.filter((outcome) => !outcome.ok).length;
  return Response.json({
    ok: failed === 0,
    experiments: outcomes.map((outcome) => outcome.ok
      ? { experiment: outcome.experiment, changed: outcome.result.snapshot.decision.changed, halted: outcome.result.snapshot.decision.halted, changes: outcome.result.changes.length }
      : { experiment: outcome.experiment, error: outcome.error }),
  }, { status: failed === 0 ? 200 : 503 });
}
