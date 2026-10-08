import { authorizeCronRequest } from "../../../../services/cronAuth";
import { reportCronFailure, runMonitoredCron } from "../../../../services/observability/cronMonitor";
import { vmModelPlaneRevoker } from "../../../../services/vms/modelPlaneGateway";
import { vmTeamDirectory } from "../../../../services/vms/teamDirectory";
import {
  reapStaleVmTunnels,
  reconcileVmProviderStatuses,
  runVmWorkflow,
} from "../../../../services/vms/workflows";


export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  return runMonitoredCron("vm-reconcile", async () => {
    try {
      // Machines the provider reports gone get their coderouter tokens revoked.
      const result = await runVmWorkflow(reconcileVmProviderStatuses({ modelPlane: vmModelPlaneRevoker(), teamDirectory: vmTeamDirectory() }));
      return Response.json({ ok: true, ...result, staleTunnels: await reapTunnels() });
    } catch (err) {
      reportCronFailure("vm-reconcile", err);
      return Response.json({ error: "vm_reconcile_failed" }, { status: 500 });
    }
  });
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
