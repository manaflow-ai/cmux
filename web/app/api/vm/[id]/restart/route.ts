import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { restartVm } from "../../../../../services/vms/workflows";

// Force a provider-level reboot. The route never probes the guest first, so a
// machine whose exec/daemon channel is frozen can still be recovered.
export const maxDuration = 300;

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/restart",
    { "cmux.vm.operation": "restart" },
    "/api/vm/[id]/restart POST failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      const run = await runVmRoute(restartVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
      }), { request, deadline: { operation: "restart" } });
      if (!run.ok) return run.response;
      return jsonResponse({ id: run.value.id, status: run.value.status });
    },
  );
}
