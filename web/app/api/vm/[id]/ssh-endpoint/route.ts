import {
  jsonResponse,
  resolveVmRouteAccountScope,
  vmResourceErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { openSshEndpoint, runVmWorkflow } from "../../../../../services/vms/workflows";

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/ssh-endpoint",
    { "cmux.vm.operation": "open_ssh" },
    "/api/vm/[id]/ssh-endpoint failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      try {
        const endpoint = await runVmWorkflow(openSshEndpoint({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          callerPlanId: account.entitlements.planId,
          teamIds: user.teamIds,
          providerVmId: id,
        }));
        setSpanAttributes(span, { "cmux.ssh.credential_kind": endpoint.credential.kind });
        return jsonResponse(endpoint);
      } catch (error) {
        const response = vmResourceErrorResponse(error, id);
        if (response) return response;
        throw error;
      }
    },
  );
}
