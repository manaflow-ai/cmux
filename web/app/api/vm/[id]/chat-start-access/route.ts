import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { currentVmChatStartAccess } from "../../../../../services/vms/chatGrants";
import { vmTeamDirectory } from "../../../../../services/vms/teamDirectory";

// Current authority for ONE new app-managed chat start, independent of the caller's existing
// Cloud link. A GET performs no provider attach, wake, lease creation or usage event. Return only
// the caller's own ability ("owner", "granted", "none"), with no teammate/grant roster.
export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/chat-start-access",
    { "cmux.vm.operation": "read_chat_start_access" },
    "/api/vm/[id]/chat-start-access failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      const run = await runVmRoute(currentVmChatStartAccess({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        teamDirectory: vmTeamDirectory(),
      }), { request });
      if (!run.ok) return run.response;
      if (!run.value.ok) return jsonResponse(run.value.refusal, run.value.refusal.status, { "cache-control": "no-store" });
      return jsonResponse({ chatStart: run.value.value }, 200, { "cache-control": "no-store" });
    },
  );
}
