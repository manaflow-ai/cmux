import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { resumeVm } from "../../../../../services/vms/workflows";

// Wake a parked machine (`cmux vm resume <id>`) through the same suspended-resume
// path every open and exec uses, so plan limits and the free window apply. A
// running machine answers 200 `running` (idempotent); a provider without resume
// answers 501 vm_operation_unsupported.

// Resume waits for the provider to report running (the same budget as an attach).
export const maxDuration = 960;

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/resume",
    { "cmux.vm.operation": "resume" },
    "/api/vm/[id]/resume POST failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      const run = await runVmRoute(resumeVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        maxActiveVms: account.entitlements.maxActiveVms,
        callerPlanId: account.entitlements.planId,
      }), { request });
      if (!run.ok) return run.response;
      return jsonResponse({ id: run.value.id, status: run.value.status });
    },
  );
}
