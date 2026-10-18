import { resolveVmRouteAccountScope, withAuthedVmApiRoute } from "../../../../services/vms/routeHelpers";
import { persistentWorkspaceServiceForRequest } from "../../../../services/vms/persistentWorkspaceComposition";
import { workspaceHttp, workspaceHttpError } from "../../../../services/vms/workspaceHttp";
type WorkspaceParams = { params: Promise<{ id: string }> };
async function handle(request: Request, { params }: WorkspaceParams): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/workspaces/[id]", { "cmux.vm.operation": "workspace_lifecycle" }, "/api/workspaces/[id] failed", async ({ user }) => {
    const account = resolveVmRouteAccountScope(user, request);
    if (!account.ok) return account.response;
    try {
      const { id } = await params;
      return workspaceHttp(request, await persistentWorkspaceServiceForRequest({ user, entitlements: account.entitlements, runtimeId: id }), {
        ownerId: user.id, tenantId: account.entitlements.billingTeamId ?? user.billingTeamId,
      }, id);
    } catch (error) { return workspaceHttpError(error); }
  });
}
export const GET = handle;
export const POST = handle;
