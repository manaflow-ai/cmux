import { NextRequest } from "next/server";

import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { isAdminUser } from "../../../../services/admin/access";
import {
  ADMIN_USER_SEARCH_MIN_QUERY_LENGTH,
  AdminGrantConflictError,
  AdminUserNotFoundError,
  isAdminGrantablePlanId,
  searchAdminUsers,
  setManualPlanGrant,
} from "../../../../services/admin/proGrants";
import { authProviderErrorResponse } from "../../../../services/vms/authErrors";
import {
  enforceBrowserMutationProtection,
  jsonResponse,
  parseBearer,
} from "../../../../services/vms/routeHelpers";

const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;
const MAX_QUERY_LENGTH = 200;

type AdminPrincipal = {
  readonly id: string;
  readonly primaryEmail: string | null;
};

type AdminGate =
  | { readonly ok: true; readonly admin: AdminPrincipal }
  | { readonly ok: false; readonly response: Response };

/** GET /api/admin/users?q=<email or name> — admin-only user search. */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const query = (request.nextUrl.searchParams.get("q") ?? "").trim();
  if (query.length < ADMIN_USER_SEARCH_MIN_QUERY_LENGTH || query.length > MAX_QUERY_LENGTH) {
    return jsonResponse({ error: "invalid_query" }, 400);
  }
  const users = await searchAdminUsers(query);
  return jsonResponse({ users });
}

/** POST /api/admin/users { userId, plan: "pro" | "founders" | null } */
export async function POST(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "invalid_body" }, 400);
  }
  const parsed = parseGrantBody(body);
  if (!parsed) return jsonResponse({ error: "invalid_body" }, 400);

  try {
    const user = await setManualPlanGrant({
      targetUserId: parsed.userId,
      plan: parsed.plan,
      admin: gate.admin,
    });
    return jsonResponse({ user });
  } catch (error) {
    if (error instanceof AdminUserNotFoundError) {
      return jsonResponse({ error: "user_not_found" }, 404);
    }
    if (error instanceof AdminGrantConflictError) {
      return jsonResponse({ error: "mutation_in_progress" }, 409);
    }
    throw error;
  }
}

async function requireAdmin(request: NextRequest): Promise<AdminGate> {
  if (!isStackConfigured()) {
    return { ok: false, response: jsonResponse({ error: "unavailable" }, 503) };
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
    return { ok: false, response: authProviderErrorResponse(error, "admin.users.auth") };
  }
  if (!user || user.isAnonymous) {
    return { ok: false, response: jsonResponse({ error: "unauthorized" }, 401) };
  }
  if (!isAdminUser(user)) {
    return { ok: false, response: jsonResponse({ error: "forbidden" }, 403) };
  }
  return { ok: true, admin: { id: user.id, primaryEmail: user.primaryEmail ?? null } };
}

function parseGrantBody(
  body: unknown,
): { userId: string; plan: "pro" | "founders" | null } | null {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const { userId, plan } = body as { userId?: unknown; plan?: unknown };
  if (typeof userId !== "string" || !userId.trim()) return null;
  if (plan === null) return { userId: userId.trim(), plan: null };
  if (!isAdminGrantablePlanId(plan)) return null;
  return { userId: userId.trim(), plan };
}
