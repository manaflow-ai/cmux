import type { NextRequest } from "next/server";

import { getStackServerApp, isStackConfigured } from "../../app/lib/stack";
import { authProviderErrorResponse } from "../vms/authErrors";
import { jsonResponse, parseBearer } from "../vms/routeHelpers";
import { isAdminUser } from "./access";

const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;

export type AdminPrincipal = {
  readonly id: string;
  readonly primaryEmail: string | null;
};

export type AdminGate =
  | { readonly ok: true; readonly admin: AdminPrincipal }
  | { readonly ok: false; readonly response: Response };

/** Admin user data must never land in a shared or browser cache. */
export function adminJsonResponse(data: unknown, status = 200): Response {
  const response = jsonResponse(data, status);
  response.headers.set("cache-control", "no-store");
  return response;
}

/**
 * Resolves the caller (cookie session or native bearer pair) and requires a
 * verified company email. 401 for signed-out or anonymous callers, 403 for
 * everyone who is not an admin.
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
    user = await loadUser();
  } catch (error) {
    return { ok: false, response: authProviderErrorResponse(error, "admin.auth") };
  }
  if (!user || user.isAnonymous) {
    return { ok: false, response: adminJsonResponse({ error: "unauthorized" }, 401) };
  }
  if (!isAdminUser(user)) {
    return { ok: false, response: adminJsonResponse({ error: "forbidden" }, 403) };
  }
  return { ok: true, admin: { id: user.id, primaryEmail: user.primaryEmail ?? null } };
}

export async function readJsonBody(request: NextRequest): Promise<unknown | undefined> {
  try {
    return await request.json();
  } catch {
    return undefined;
  }
}
