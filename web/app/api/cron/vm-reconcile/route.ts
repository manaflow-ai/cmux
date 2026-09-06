import { authorizeCronRequest } from "../../../../services/cronAuth";
import { vmModelPlaneRevoker } from "../../../../services/vms/modelPlaneGateway";
import {
  reconcileVmProviderStatuses,
  runVmWorkflow,
} from "../../../../services/vms/workflows";


export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  try {
    // Machines the provider reports gone get their coderouter tokens revoked.
    const result = await runVmWorkflow(reconcileVmProviderStatuses({ modelPlane: vmModelPlaneRevoker() }));
    return Response.json({ ok: true, ...result });
  } catch (err) {
    console.error("[VM] cron status reconcile failed", err);
    return Response.json({ error: "vm_reconcile_failed" }, { status: 500 });
  }
}
