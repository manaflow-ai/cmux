import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { pauseVm } from "../../../../../services/vms/workflows";

// Park a machine (`cmux vm pause <id>`): compute stops billing, the persistent
// home and the daemon's durable session stay. A paused machine answers 200
// again (idempotent); a provider without pause answers 501 vm_operation_unsupported.

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/pause",
    { "cmux.vm.operation": "pause" },
    "/api/vm/[id]/pause POST failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      const run = await runVmRoute(pauseVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
      }), { request });
      if (!run.ok) return run.response;
      return jsonResponse({ id: run.value.id, status: run.value.status });
    },
  );
}
