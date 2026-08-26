import {
  reconcileVmProviderStatuses,
  runVmWorkflow,
} from "../../../../services/vms/workflows";
import {
  recordSpanError,
  setSpanAttributes,
  withVmSpan,
} from "../../../../services/vms/telemetry";


export async function GET(request: Request): Promise<Response> {
  const secret = process.env.CRON_SECRET;
  if (!secret || request.headers.get("authorization") !== `Bearer ${secret}`) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  return withVmSpan("vm.reconcile", { "cmux.vm.trigger": "cron" }, async (span) => {
    try {
      const result = await runVmWorkflow(reconcileVmProviderStatuses());
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
