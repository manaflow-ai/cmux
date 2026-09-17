import { authorizeCronRequest } from "../../../../services/cronAuth";
import { vmModelPlaneRevoker } from "../../../../services/vms/modelPlaneGateway";
import {
  reconcileVmProviderStatuses,
  runVmWorkflow,
  sweepExpiredVms,
} from "../../../../services/vms/workflows";

export const maxDuration = 60;

export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  try {
    // Cost cleanup runs before status probes. Failed destroys remain retryable,
    // while provider-reported deletions revoke their model-plane credentials.
    const expired = await runVmWorkflow(sweepExpiredVms({ modelPlane: vmModelPlaneRevoker() }));
    const result = await runVmWorkflow(reconcileVmProviderStatuses({ modelPlane: vmModelPlaneRevoker() }));
    return Response.json({ ok: true, ...result, expired });
  } catch (err) {
    console.error("[VM] cron reconcile/sweep failed", err);
    return Response.json({ error: "vm_reconcile_failed" }, { status: 500 });
  }
}
