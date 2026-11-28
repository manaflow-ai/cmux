import { getStackServerApp, isStackConfigured } from "../../../app/lib/stack";
import { authProviderErrorResponse } from "../../vms/authErrors";
import { jsonResponse, parseBearer } from "../../vms/routeHelpers";

function loadUser(request: Request) {
  const app = getStackServerApp();
  const bearer = parseBearer(request);
  return bearer
    ? app.getUser({ tokenStore: { accessToken: bearer.accessToken, refreshToken: bearer.refreshToken } })
    : app.getUser({ or: "return-null", tokenStore: request as unknown as { headers: { get(name: string): string | null } } });
}

export type AppleRouteUser = NonNullable<Awaited<ReturnType<typeof loadUser>>>;

export type AppleRouteAuth =
  | { readonly ok: true; readonly user: AppleRouteUser }
  | { readonly ok: false; readonly response: Response };

/**
 * The signed-in user of an Apple billing request, through the same Stack
 * auth `/api/billing/plan` uses: the native bearer and refresh token headers
 * from the iOS app, else the browser session cookie. Purchases need a real
 * account, so anonymous users are refused like signed-out ones.
 */
export async function authenticateAppleBillingRequest(request: Request, route: string): Promise<AppleRouteAuth> {
  if (!isStackConfigured()) {
    return { ok: false, response: jsonResponse({ error: "billing_unavailable" }, 503) };
  }
  let user: Awaited<ReturnType<typeof loadUser>>;
  try {
    user = await loadUser(request);
  } catch (error) {
    return { ok: false, response: authProviderErrorResponse(error, `${route}.auth`) };
  }
  if (!user || user.isAnonymous) {
    return { ok: false, response: jsonResponse({ error: "unauthorized" }, 401, { "cache-control": "no-store" }) };
  }
  return { ok: true, user };
}
