import { getStackServerApp } from "@/app/lib/stack";
import {
  jsonResponse,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "@/services/vms/routeHelpers";
import { optionalString, parseLenientObjectBody } from "@/services/vms/routeInput";
import {
  renameVmAccessGrant,
  revokeVmAccessGrant,
  runVmWorkflow,
} from "@/services/vms/workflows";

const MAX_DISPLAY_NAME_LENGTH = 63;
type AccessGrantRouteContext = {
  readonly params: Promise<{ readonly id: string }>;
};

export async function PATCH(
  request: Request,
  context: AccessGrantRouteContext,
): Promise<Response> {
  const { id } = await context.params;
  return withAuthedVmApiRoute(
    request,
    "/api/vm/access-grants/[id]",
    { "cmux.vm.operation": "rename_access_grant" },
    "/api/vm/access-grants/[id] failed",
    async ({ user }) => {
      const body = await parseLenientObjectBody(request);
      const raw = optionalString(body.displayName ?? body.display_name);
      if (raw && raw.length > MAX_DISPLAY_NAME_LENGTH) {
        return vmErrorResponse({
          error: "invalid_request",
          status: 400,
          message: `displayName must be at most ${MAX_DISPLAY_NAME_LENGTH} characters.`,
          action: "Use a shorter Mac name.",
          phase: "network",
        });
      }
      const renamed = await runVmWorkflow(renameVmAccessGrant({
        userId: user.id,
        accessGrantId: id,
        displayName: raw || null,
      }));
      if (!renamed) {
        return vmErrorResponse({
          error: "vm_access_grant_not_found",
          status: 404,
          message: "This Mac access record was not found.",
          action: "Reload the page and try again.",
          phase: "network",
        });
      }
      return jsonResponse({ renamed: true });
    },
  );
}

export async function DELETE(
  request: Request,
  context: AccessGrantRouteContext,
): Promise<Response> {
  const { id } = await context.params;
  return withAuthedVmApiRoute(
    request,
    "/api/vm/access-grants/[id]",
    { "cmux.vm.operation": "revoke_access_grant" },
    "/api/vm/access-grants/[id] failed",
    async ({ user }) => {
      const result = await runVmWorkflow(revokeVmAccessGrant({
        userId: user.id,
        accessGrantId: id,
      }));
      if (result.revoked && result.stackSessionIds.length > 0) {
        const stackUser = await getStackServerApp().getUser({ tokenStore: request });
        if (stackUser?.id === user.id) {
          await Promise.allSettled(
            result.stackSessionIds.map((sessionId) => stackUser.revokeSession(sessionId)),
          );
        }
      }
      return jsonResponse({ revoked: result.revoked });
    },
  );
}
