import { resolveVmProvisioningAccountScope, withAuthedVmApiRoute } from "../../../services/vms/routeHelpers";
import { persistentWorkspaceServiceForRequest } from "../../../services/vms/persistentWorkspaceComposition";
import { workspaceHttp, workspaceHttpError } from "../../../services/vms/workspaceHttp";
export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/workspaces", { "cmux.vm.operation": "workspace_create" }, "/api/workspaces POST failed", async ({ user }) => {
    const scope = await resolveVmProvisioningAccountScope(user, request);
    if (!scope.ok) return scope.response;
    try {
      return workspaceHttp(request, await persistentWorkspaceServiceForRequest({ user, entitlements: scope.entitlements }), {
        ownerId: user.id, tenantId: scope.entitlements.billingTeamId ?? user.billingTeamId,
      });
    } catch (error) { return workspaceHttpError(error); }
  });
}
