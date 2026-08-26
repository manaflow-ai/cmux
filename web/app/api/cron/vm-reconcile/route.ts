import {
  reconcileCreditReservations,
  reconcileVmProviderStatuses,
  runVmWorkflow,
  sweepStuckProvisioningVms,
} from "../../../../services/vms/workflows";


export async function GET(request: Request): Promise<Response> {
  const secret = process.env.CRON_SECRET;
  if (!secret || request.headers.get("authorization") !== `Bearer ${secret}`) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  try {
    const providerStatuses = await runVmWorkflow(reconcileVmProviderStatuses());
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
