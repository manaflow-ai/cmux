import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../../services/telemetry";
import { runVmRoute } from "../../../../../../services/vms/routeWorkflow";
import { deleteVmSnapshot } from "../../../../../../services/vms/workflows";

// Delete one snapshot of a machine the caller owns (`cmux vm snapshot rm <m> <snapshot>`).
// Scoped to the machine: a snapshot that does not exist, or was taken from
// another machine, answers 404 vm_snapshot_not_found; a provider that cannot
// delete snapshots answers 501 vm_operation_unsupported.

export async function DELETE(
  request: Request,
  { params }: { params: Promise<{ id: string; snapshotId: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/snapshots/[snapshotId]",
    { "cmux.vm.operation": "snapshot.delete" },
    "/api/vm/[id]/snapshots/[snapshotId] DELETE failed",
    async ({ user, span }) => {
      const { id, snapshotId } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id, "cmux.snapshot.id": snapshotId });
      const run = await runVmRoute(deleteVmSnapshot({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        snapshotId,
      }), { request });
      if (!run.ok) return run.response;
      return jsonResponse({ id: run.value.id, deleted: run.value.deleted });
    },
  );
}
