import { isStackConfigured } from "@/app/lib/stack";
import { isVaultEnabled } from "@/services/vault/config";
import {
  isSubrouterAuthorizationError,
  verifyBrowserSessionRequest,
  withSubrouterAuthorizationDeadline,
} from "@/services/vms/auth";
import { jsonResponse } from "@/services/vms/routeHelpers";
import type { DashboardSessionResponse } from "@/dashboard-app/lib/session-types";

/**
 * The signed-in browser user and the build flags the dashboard SPA needs to
 * choose its navigation. 401 sends the SPA to sign-in; 503 renders recovery
 * in place because a Stack outage is not a signed-out session.
 */
export async function GET(request: Request) {
  if (!isStackConfigured()) {
    return jsonResponse({ error: { code: "not_configured" } }, 404);
  }
  let user: Awaited<ReturnType<typeof verifyBrowserSessionRequest>>;
  try {
    user = await withSubrouterAuthorizationDeadline((signal) =>
      verifyBrowserSessionRequest(request, signal)
    );
  } catch (error) {
    if (isSubrouterAuthorizationError(error)) {
      return jsonResponse({ error: { code: "authorization_unavailable" } }, 503);
    }
    throw error;
  }
  if (!user) return jsonResponse({ error: { code: "unauthorized" } }, 401);
  const body: DashboardSessionResponse = {
    user: {
      id: user.id,
      displayName: user.displayName ?? null,
      primaryEmail: user.primaryEmail ?? null,
      primaryEmailVerified: user.primaryEmailVerified === true,
      profileImageUrl: user.profileImageUrl ?? null,
      selectedTeamId: user.selectedTeam?.id ?? null,
    },
    flags: { vaultEnabled: isVaultEnabled() },
  };
  return jsonResponse(body, 200, { "cache-control": "private, no-store" });
}
