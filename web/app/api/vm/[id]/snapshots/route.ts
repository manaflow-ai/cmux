import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { listVmSnapshots } from "../../../../../services/vms/workflows";

// Every snapshot taken from a machine the caller owns (`cmux vm snapshot ls <m>`),
// newest first. The provider is the source of truth for what still exists; a
// provider that cannot enumerate snapshots answers 501 vm_operation_unsupported.

export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/snapshots",
    { "cmux.vm.operation": "snapshot.list" },
    "/api/vm/[id]/snapshots GET failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      const run = await runVmRoute(listVmSnapshots({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
      }), { request });
      if (!run.ok) return run.response;
      return jsonResponse({
        id,
        snapshots: run.value.map((snapshot) => ({
          id: snapshot.id,
          name: snapshot.name ?? null,
          createdAt: new Date(snapshot.createdAt).toISOString(),
        })),
      });
    },
  );
}
