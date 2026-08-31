import {
  reconcileVmProviderStatuses,
  runVmWorkflow,
  sweepExpiredVms,
} from "../../../../services/vms/workflows";

export const maxDuration = 60;

export async function GET(request: Request): Promise<Response> {
  const secret = process.env.CRON_SECRET;
  if (!secret || request.headers.get("authorization") !== `Bearer ${secret}`) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  try {
    // Run cost cleanup first. Provider status probes can consume the route's
    // time budget, while each failed expiry destroy remains retryable.
    const expired = await runVmWorkflow(sweepExpiredVms());
    const result = await runVmWorkflow(reconcileVmProviderStatuses());
    return Response.json({ ok: true, ...result, expired });
  } catch (err) {
    console.error("[VM] cron reconcile/sweep failed", err);
    return Response.json({ error: "vm_reconcile_failed" }, { status: 500 });
  }
}
