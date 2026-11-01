import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
  type AuthedVmRouteContext,
} from "../../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../../services/telemetry";
import { runVmRoute } from "../../../../../../services/vms/routeWorkflow";
import { grantVmChat, revokeVmChat, vmTeamAdminCheck } from "../../../../../../services/vms/chatGrants";
import { vmTeamDirectory } from "../../../../../../services/vms/teamDirectory";

type Params = { params: Promise<{ id: string; userId: string }> };

// Share app-started chats on a team Cloud machine with one teammate (PUT), or
// take the share back (DELETE). The machine's creator or a team admin only;
// the teammate must be on the machine's team (services/vms/chatGrants.ts).
export async function PUT(request: Request, { params }: Params): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/chat-grants/[userId]",
    { "cmux.vm.operation": "grant_chat" },
    "/api/vm/[id]/chat-grants/[userId] failed",
    (context) => share(request, params, context, "grant"),
  );
}

export async function DELETE(request: Request, { params }: Params): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/chat-grants/[userId]",
    { "cmux.vm.operation": "revoke_chat_grant" },
    "/api/vm/[id]/chat-grants/[userId] failed",
    (context) => share(request, params, context, "revoke"),
  );
}

async function share(
  request: Request,
  params: Params["params"],
  { user, span }: AuthedVmRouteContext,
  action: "grant" | "revoke",
): Promise<Response> {
  const { id, userId } = await params;
  const account = resolveVmRouteAccountScope(user, request);
  if (!account.ok) return account.response;
  setSpanAttributes(span, { "cmux.vm.id": id });
  const input = {
    userId: user.id,
    billingTeamId: account.entitlements.billingTeamId,
    teamIds: user.teamIds,
    providerVmId: id,
    targetUserId: userId,
    teamDirectory: vmTeamDirectory(),
    isTeamAdmin: vmTeamAdminCheck(),
  };
  if (action === "grant") {
    const run = await runVmRoute(grantVmChat(input), { request });
    if (!run.ok) return run.response;
    if (!run.value.ok) return jsonResponse(run.value.refusal, run.value.refusal.status);
    return jsonResponse({ grant: run.value.value });
  }
  const run = await runVmRoute(revokeVmChat(input), { request });
  if (!run.ok) return run.response;
  if (!run.value.ok) return jsonResponse(run.value.refusal, run.value.refusal.status);
  return jsonResponse(run.value.value);
}
