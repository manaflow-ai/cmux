import {
  resolveVmRouteAccountScope,
  vmResourceErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { refreshVmRelayTickets, runVmWorkflow } from "../../../../../services/vms/workflows";

/**
 * Refreshes the short-lived Connect tickets used by the local cmux-tui
 * process. The response contains no provider credential and is never cached.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/relay-ticket",
    { "cmux.vm.operation": "refresh_relay_ticket" },
    "/api/vm/[id]/relay-ticket POST failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      try {
        const result = await runVmWorkflow(refreshVmRelayTickets({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          teamIds: user.teamIds,
          providerVmId: id,
          callerPlanId: account.entitlements.planId,
        }));
        return new Response(JSON.stringify(result), {
          status: 200,
          headers: {
            "content-type": "application/json",
            "cache-control": "no-store, no-cache, max-age=0",
          },
        });
      } catch (err) {
        const response = vmResourceErrorResponse(err, id);
        if (response) return response;
        throw err;
      }
    },
  );
}
