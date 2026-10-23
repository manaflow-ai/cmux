import {
  jsonResponse,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "@/services/vms/routeHelpers";
import { optionalString, parseLenientObjectBody } from "@/services/vms/routeInput";
import { runVmRoute } from "@/services/vms/routeWorkflow";
import {
  renameVmAccessGrant,
  revokeVmAccessGrant,
} from "@/services/vms/workflows";
import {
  FIRST_CRON_RETRY_DELAY_MS,
  revokeAccessGrantStackSessions,
  stackServerSessionRevoker,
} from "@/services/vms/stackSessionRevocations";
import { databaseStackSessionRevocationStore } from "@/services/vms/stackSessionRevocationStore";

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
      const renamed = await runVmRoute(renameVmAccessGrant({
        userId: user.id,
        accessGrantId: id,
        displayName: raw || null,
      }), { request });
      if (!renamed.ok) return renamed.response;
      if (!renamed.value) {
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
      const revoke = await runVmRoute(revokeVmAccessGrant({
        userId: user.id,
        accessGrantId: id,
        revokeStackSessions: { firstRetryAt: new Date(Date.now() + FIRST_CRON_RETRY_DELAY_MS) },
      }), { request });
      if (!revoke.ok) return revoke.response;
      const result = revoke.value;
      if (!result.revoked) return jsonResponse({ revoked: false });
      // The grant and its tunnels are already cut above, and the Stack
      // sessions that enrolled it were queued in the same transaction as the
      // grant revocation. This is the first attempt; a throttled or failed
      // one is retried by the vm-reconcile cron, and the answer says
      // `pending` until Stack has accepted every session.
      const sessionRevocation = await revokeAccessGrantStackSessions({
        stackSessionIds: result.stackSessionIds,
        store: databaseStackSessionRevocationStore(),
        revoke: stackServerSessionRevoker(),
      });
      return jsonResponse({ revoked: true, sessionRevocation });
    },
  );
}
