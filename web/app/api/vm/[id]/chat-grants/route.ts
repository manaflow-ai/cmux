import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { listVmChatGrants } from "../../../../../services/vms/chatGrants";

// Who, besides its creator, may start app chats on a team Cloud machine
// (services/vms/chatGrants.ts). Anyone who can reach the machine may read it.
export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/chat-grants",
    { "cmux.vm.operation": "list_chat_grants" },
    "/api/vm/[id]/chat-grants failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      const run = await runVmRoute(listVmChatGrants({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
      }), { request });
      if (!run.ok) return run.response;
      const outcome = run.value;
      if (!outcome.ok) return jsonResponse(outcome.refusal, outcome.refusal.status);
      return jsonResponse({ grants: outcome.value });
    },
  );
}
