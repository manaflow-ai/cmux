import {
  jsonResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { invalidateNativeAuthCacheForTokens } from "../../../../../services/vms/auth";
import {
  revokeUserVmAccess,
  runVmWorkflow,
} from "../../../../../services/vms/workflows";

/**
 * Ends endpoint access issued to the current native session's account.
 *
 * The VM itself is durable and remains owned by the account; this route only
 * invalidates already-minted PTY/RPC/preview credentials. It is called by the
 * native sign-out tail after local workspace teardown and before Stack session
 * revocation completes.
 */
export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/leases/revoke",
    { "cmux.vm.operation": "revoke_access" },
    "/api/vm/leases/revoke failed",
    async ({ user }) => {
      const authorization = request.headers.get("authorization") ?? "";
      const accessToken = authorization.slice("bearer ".length).trim();
      const refreshToken = request.headers.get("x-stack-refresh-token")?.trim() ?? "";
      if (accessToken && refreshToken) {
        // The route may have served its user from the positive verification
        // cache. Remove that exact pair before returning so a follow-up VM
        // request on this process cannot reuse the stale verdict while Stack
        // Auth revocation is still in flight.
        invalidateNativeAuthCacheForTokens({ accessToken, refreshToken });
      }
      const result = await runVmWorkflow(revokeUserVmAccess({ userId: user.id }));
      return jsonResponse({
        ok: true,
        revoked: result.revoked,
        cleanupFailures: result.cleanupFailures,
      });
    },
  );
}
