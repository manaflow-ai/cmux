import { recordSpanError, setSpanAttributes, withPrioritySpan } from "../../../../services/telemetry";
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

  return withPrioritySpan("cmux-vm", "vm.reconcile", {
    "cmux.subsystem": "vm-cloud",
    "cmux.vm.trigger": "cron",
  }, async (span) => {
    try {
      // Machines the provider reports gone get their coderouter tokens revoked.
      const result = await runVmWorkflow(reconcileVmProviderStatuses({ modelPlane: vmModelPlaneRevoker() }));
      setSpanAttributes(span, {
        "cmux.vm.reconcile.checked": result.checked,
        "cmux.vm.reconcile.updated": result.updated,
        "cmux.vm.reconcile.destroyed": result.destroyed,
        "cmux.vm.reconcile.skipped": result.skipped,
        "cmux.vm.reconcile.no_get_status": result.skippedNoGetStatus,
        "cmux.vm.outcome": "success",
      });
      return Response.json({ ok: true, ...result });
    } catch (err) {
      recordSpanError(span, err);
      setSpanAttributes(span, { "cmux.vm.outcome": "failure" });
      console.error("[VM] cron status reconcile failed", err);
      return Response.json({ error: "vm_reconcile_failed" }, { status: 500 });
    }
  });
}
