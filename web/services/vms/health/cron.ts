import { authorizeCronRequest } from "../../cronAuth";
import type { VmHealthAlertOutcome } from "../../observability/vmHealthAlerts";
import type { VmHealthReport } from "./types";
import type { VmHealthSweepOptions, VmHealthSweepResult } from "./sweep";

/** Staff page for the alert link; the dashboard route that reads the stored snapshot. */
export const VM_HEALTH_PAGE_PATH = "/dashboard/ops/cloud-vms";

export type VmHealthCronDeps = {
  readonly sweep: (options: VmHealthSweepOptions) => Promise<VmHealthSweepResult>;
  readonly alert: (report: VmHealthReport, pageUrl: string | null) => Promise<VmHealthAlertOutcome>;
  readonly env: Record<string, string | undefined>;
};

/**
 * GET /api/cron/vm-health. Cron-secret gated; runs one read-only sweep inside
 * the route's time budget, stores it, and hands the result to the alert path.
 * The response carries counts only, never VM owners.
 */
export async function handleVmHealthCron(request: Request, deps: VmHealthCronDeps): Promise<Response> {
  const auth = authorizeCronRequest(request);
  if (!auth.ok) {
    return Response.json({ error: auth.reason === "cron_secret_missing" ? "cron_not_configured" : "unauthorized" }, {
      status: auth.reason === "cron_secret_missing" ? 503 : 401,
    });
  }
  const result = await deps.sweep(sweepOptionsFromEnv(deps.env));
  const origin = deps.env.CMUX_PUBLIC_ORIGIN?.trim() || new URL(request.url).origin;
  const alert = await deps.alert(result.report, `${origin}${VM_HEALTH_PAGE_PATH}`);
  const { report } = result;
  // A failed store still alerts on what the sweep found, then answers 500 so
  // the cron monitor shows the page is going stale.
  return Response.json({
    ok: result.storeError === null,
    snapshotId: result.snapshotId,
    storeError: result.storeError,
    durationMs: report.durationMs,
    attentionNeeded: report.attention.needed,
    reasons: report.attention.reasons.map((reason) => reason.code),
    hung: report.hung.length,
    stuck: report.stuck.length,
    drift: report.drift.length,
    tlsRules: report.tls?.totalCount ?? null,
    coverage: report.coverage,
    errors: report.errors.map((error) => error.stage),
    pruned: result.pruned,
    alert,
  }, { status: result.storeError === null ? 200 : 500 });
}

/** Operator overrides; anything unparseable keeps the default. */
export function sweepOptionsFromEnv(env: Record<string, string | undefined>): VmHealthSweepOptions {
  const budgetMs = positiveInt(env.CMUX_VM_HEALTH_BUDGET_MS);
  const probeTimeoutMs = positiveInt(env.CMUX_VM_HEALTH_PROBE_TIMEOUT_MS);
  const probeConcurrency = positiveInt(env.CMUX_VM_HEALTH_PROBE_CONCURRENCY);
  const tlsRuleLimit = positiveInt(env.FREESTYLE_TLS_RULE_LIMIT);
  return {
    // The route's maxDuration is 300s; keep the sweep well inside it.
    ...(budgetMs ? { budgetMs: Math.min(budgetMs, 240_000) } : {}),
    ...(probeTimeoutMs ? { probeTimeoutMs: Math.min(probeTimeoutMs, 30_000) } : {}),
    ...(probeConcurrency ? { probeConcurrency: Math.min(probeConcurrency, 64) } : {}),
    probeIdleVms: env.CMUX_VM_HEALTH_PROBE_IDLE_VMS === "1",
    ...(tlsRuleLimit ? { thresholds: { tlsRuleLimit } } : {}),
  };
}

function positiveInt(value: string | undefined): number | null {
  const trimmed = value?.trim();
  if (!trimmed || !/^[0-9]+$/.test(trimmed)) return null;
  const parsed = Number(trimmed);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}
