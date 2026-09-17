import { authorizeCronRequest } from "../../../../services/cronAuth";
import { vmModelPlaneRevoker } from "../../../../services/vms/modelPlaneGateway";
import {
  reconcileCreditReservations,
  reconcileVmProviderStatuses,
  runVmWorkflow,
  sweepStuckProvisioningVms,
} from "../../../../services/vms/workflows";


export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  try {
    const providerStatuses = await runVmWorkflow(reconcileVmProviderStatuses({ modelPlane: vmModelPlaneRevoker() }));
    // Order matters: sweep first so a crashed create's row is durably failed
    // before the reservation reconciler decides whether to refund its credit.
    const stuckProvisioning = await runVmWorkflow(sweepStuckProvisioningVms());
    const creditReservations = await runVmWorkflow(reconcileCreditReservations());
    return Response.json({
      ok: true,
      ...providerStatuses,
      stuckProvisioning,
      creditReservations,
    });
  } catch (err) {
    console.error("[VM] cron status reconcile failed", err);
    return Response.json({ error: "vm_reconcile_failed" }, { status: 500 });
  }
}
