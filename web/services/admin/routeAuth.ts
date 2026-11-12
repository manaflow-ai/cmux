import type { NextRequest } from "next/server";

import { getStackServerApp, isStackConfigured } from "../../app/lib/stack";
import { authProviderErrorResponse } from "../vms/authErrors";
import { jsonResponse, parseBearer } from "../vms/routeHelpers";
import { isAdminUser } from "./access";
import { findActiveAdminMember } from "./members";
import { withStackAuthSpan } from "../auth/stackTelemetry";

const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;

export type AdminPrincipal = {
  readonly id: string;
  readonly primaryEmail: string | null;
};

/** How the caller qualified: a verified company-domain email, or an invited member row. */
export type AdminSource = "company_domain" | "member";

export type AdminGate =
  | { readonly ok: true; readonly admin: AdminPrincipal; readonly source: AdminSource }
  | { readonly ok: false; readonly response: Response };

/** Admin user data must never land in a shared or browser cache. */
export function adminJsonResponse(data: unknown, status = 200): Response {
  const response = jsonResponse(data, status);
  response.headers.set("cache-control", "no-store");
  return response;
}

/**
 * Resolves the caller (cookie session or native bearer pair) and requires a
 * verified company email, or a verified email with an active admin_members
 * row. 401 for signed-out or anonymous callers, 403 for everyone else.
 */
export async function requireAdmin(request: NextRequest): Promise<AdminGate> {
  if (!isStackConfigured()) {
    return { ok: false, response: adminJsonResponse({ error: "unavailable" }, 503) };
  }
  const stackServerApp = getStackServerApp();
  const bearer = parseBearer(request);
  const loadUser = () => bearer
    ? stackServerApp.getUser({
        tokenStore: {
          accessToken: bearer.accessToken,
          refreshToken: bearer.refreshToken,
        },
      })
    : stackServerApp.getUser({
        or: ANONYMOUS_IF_EXISTS,
        tokenStore: request as unknown as { headers: { get(name: string): string | null } },
      });
  let user: Awaited<ReturnType<typeof loadUser>>;
  try {
    user = await withStackAuthSpan("get_user", loadUser, {
      "cmux.auth.flow": "admin_route",
    });
  } catch (error) {
    return { ok: false, response: authProviderErrorResponse(error, "admin.auth") };
  }
  if (!user || user.isAnonymous) {
    return { ok: false, response: adminJsonResponse({ error: "unauthorized" }, 401) };
  }
  const source = await resolveAdminSource(user);
  if (!source) {
    return { ok: false, response: adminJsonResponse({ error: "forbidden" }, 403) };
  }
  return { ok: true, admin: { id: user.id, primaryEmail: user.primaryEmail ?? null }, source };
}

async function resolveAdminSource(user: {
  readonly primaryEmail: string | null;
  readonly primaryEmailVerified: boolean;
  readonly isAnonymous: boolean;
}): Promise<AdminSource | null> {
  if (isAdminUser(user)) return "company_domain";
  // The member rule needs the same verified, non-anonymous mailbox as the
  // domain rule: an unverified sign-up can claim any invited address.
  if (user.isAnonymous || user.primaryEmailVerified !== true || !user.primaryEmail) return null;
  try {
    return (await findActiveAdminMember(user.primaryEmail)) ? "member" : null;
  } catch (error) {
    // A missing table or unreachable database fails closed for invited
    // members; company-domain admins never reach this lookup.
    console.error("admin.members.lookup_failed", {
      message: error instanceof Error ? error.message : String(error),
    });
    return null;
  }
}

export async function readJsonBody(request: NextRequest): Promise<unknown | undefined> {
  try {
    return await request.json();
  } catch {
    return undefined;
  }
}
