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
    const result = await runVmWorkflow(reconcileVmProviderStatuses());
    const expired = await runVmWorkflow(sweepExpiredVms());
    return Response.json({ ok: true, ...result, expired });
  } catch (err) {
    console.error("[VM] cron reconcile/sweep failed", err);
    return Response.json({ error: "vm_reconcile_failed" }, { status: 500 });
  }
}
