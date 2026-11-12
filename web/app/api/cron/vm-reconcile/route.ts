import { authorizeCronRequest } from "../../../../services/cronAuth";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";
import { vmModelPlaneRevoker } from "../../../../services/vms/modelPlaneGateway";
import { vmTeamDirectory } from "../../../../services/vms/teamDirectory";
import {
  retryPendingStackSessionRevocations,
  stackServerSessionRevoker,
} from "../../../../services/vms/stackSessionRevocations";
import { databaseStackSessionRevocationStore } from "../../../../services/vms/stackSessionRevocationStore";
import {
  reapStaleVmTunnels,
  reconcileVmProviderStatuses,
  runVmWorkflow,
} from "../../../../services/vms/workflows";

// Reconcile, tunnel reap and up to CRON_CLAIM_LIMIT concurrent Stack session
// revocations (10 s timeout each) fit well inside this.
export const maxDuration = 300;

export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  return runMonitoredCron("vm-reconcile", async () => {
    try {
      // Machines the provider reports gone get their coderouter tokens revoked.
      const result = await runVmWorkflow(reconcileVmProviderStatuses({ modelPlane: vmModelPlaneRevoker(), teamDirectory: vmTeamDirectory() }));
      return Response.json({
        ok: true,
        ...result,
        staleTunnels: await reapTunnels(),
        stackSessionRevocations: await retryStackSessionRevocations(),
      });
    } catch (err) {
      reportCronFailure("vm-reconcile", err);
      return Response.json({ error: "vm_reconcile_failed" }, { status: 500 });
    }
  });
}

/**
 * Retries Stack session revocations a revoked access grant could not finish
 * (Stack throttled, failed, or timed out). Its failure never fails the reconcile.
 */
async function retryStackSessionRevocations() {
  try {
    return await retryPendingStackSessionRevocations({
      store: databaseStackSessionRevocationStore(),
      revoke: stackServerSessionRevoker(),
      // Reported once per row, when it gives up; Sentry groups by stage.
      onGiveUp: (row) => reportCronFailure(
        "vm-reconcile",
        new Error("Stack session revocation gave up"),
        { attempts: row.attempts, error: row.error },
        { stage: "stack_session_revocation_gave_up", level: "error" },
      ),
    });
  } catch (err) {
    reportCronFailure("vm-reconcile", err, {}, { stage: "stack_session_revocation", level: "warning" });
    return { error: "stack_session_revocation_failed" };
  }
}

/** Frees private-network addresses held by replaced tunnels; its failure never fails the reconcile. */
async function reapTunnels() {
  try {
    const result = await runVmWorkflow(reapStaleVmTunnels());
    console.info("[VM] cron stale tunnel reap", JSON.stringify(result));
    return result;
  } catch (err) {
    reportCronFailure("vm-reconcile", err, {}, { stage: "tunnel_reap", level: "warning" });
    return { error: "tunnel_reap_failed" };
  }
}
