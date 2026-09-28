import { isStackConfigured } from "@/app/lib/stack";
import {
  isSubrouterAuthorizationError,
  verifyBrowserSessionRequest,
  withSubrouterAuthorizationDeadline,
} from "@/services/vms/auth";
import { jsonResponse } from "@/services/vms/routeHelpers";

export type DashboardSessionRouteUser = NonNullable<
  Awaited<ReturnType<typeof verifyBrowserSessionRequest>>
>;

const PRIVATE_NO_STORE = { "cache-control": "private, no-store" } as const;

/**
 * Runs `handler` for the signed-in browser user of a dashboard read route.
 * Signed out is 401 so the SPA goes to sign-in; a Stack outage is 503 so it
 * renders recovery instead of treating the visitor as signed out.
 */
export async function withDashboardSessionUser(
  request: Request,
  handler: (user: DashboardSessionRouteUser) => Promise<unknown>,
): Promise<Response> {
  if (!isStackConfigured()) {
    return jsonResponse({ error: { code: "not_configured" } }, 404, PRIVATE_NO_STORE);
  }
  let user: Awaited<ReturnType<typeof verifyBrowserSessionRequest>>;
  try {
    user = await withSubrouterAuthorizationDeadline((signal) =>
      verifyBrowserSessionRequest(request, signal)
    );
  } catch (error) {
    if (isSubrouterAuthorizationError(error)) {
      return jsonResponse({ error: { code: "authorization_unavailable" } }, 503, PRIVATE_NO_STORE);
    }
    throw error;
  }
  if (!user) return jsonResponse({ error: { code: "unauthorized" } }, 401, PRIVATE_NO_STORE);
  return jsonResponse(await handler(user), 200, PRIVATE_NO_STORE);
}
