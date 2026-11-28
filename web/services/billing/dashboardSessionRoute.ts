import { isStackConfigured } from "@/app/lib/stack";
import {
  isSubrouterAuthorizationError,
  verifyBrowserSessionRequest,
  withSubrouterAuthorizationDeadline,
} from "@/services/vms/auth";

export type DashboardSessionRouteUser = NonNullable<
  Awaited<ReturnType<typeof verifyBrowserSessionRequest>>
>;

export type DashboardSessionResolution =
  | { readonly ok: true; readonly user: DashboardSessionRouteUser }
  | { readonly ok: false; readonly status: 401 | 404 | 503; readonly reason: string };

/**
 * The signed-in browser user of a dashboard request. Signed out is 401 so the
 * SPA goes to sign-in; a Stack outage is 503 so it renders recovery instead
 * of treating the visitor as signed out.
 */
export async function resolveDashboardSessionUser(request: Request): Promise<DashboardSessionResolution> {
  if (!isStackConfigured()) return { ok: false, status: 404, reason: "not_configured" };
  let user: Awaited<ReturnType<typeof verifyBrowserSessionRequest>>;
  try {
    user = await withSubrouterAuthorizationDeadline((signal) =>
      verifyBrowserSessionRequest(request, signal)
    );
  } catch (error) {
    if (isSubrouterAuthorizationError(error)) {
      return { ok: false, status: 503, reason: "authorization_unavailable" };
    }
    throw error;
  }
  if (!user) return { ok: false, status: 401, reason: "unauthorized" };
  return { ok: true, user };
}
