import { NextRequest } from "next/server";

import {
  ADMIN_USER_SEARCH_MIN_QUERY_LENGTH,
  AdminGrantConflictError,
  AdminUserNotFoundError,
  isAdminGrantablePlanId,
  isMissingGrantsTableError,
  listPendingEmailGrants,
  searchAdminTeams,
  searchAdminUsers,
  setManualPlanGrant,
} from "../../../../services/admin/proGrants";
import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
} from "../../../../services/admin/routeAuth";
import { enforceBrowserMutationProtection } from "../../../../services/vms/routeHelpers";

const MAX_QUERY_LENGTH = 200;

/** GET /api/admin/users?q=<email, name, or id> — users, teams, and pending email grants. */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const query = (request.nextUrl.searchParams.get("q") ?? "").trim();
  if (query.length < ADMIN_USER_SEARCH_MIN_QUERY_LENGTH || query.length > MAX_QUERY_LENGTH) {
    return adminJsonResponse({ error: "invalid_query" }, 400);
  }
  const [users, teams, pendingGrants] = await Promise.all([
    searchAdminUsers(query),
    searchAdminTeams(query),
    listPendingEmailGrantsSafely(query),
  ]);
  return adminJsonResponse({ users, teams, pendingGrants });
}

/** POST /api/admin/users { userId, plan: "pro" | "founders" | null } */
export async function POST(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const parsed = parseGrantBody(await readJsonBody(request));
  if (!parsed) return adminJsonResponse({ error: "invalid_body" }, 400);

  try {
    const user = await setManualPlanGrant({
      targetUserId: parsed.userId,
      plan: parsed.plan,
      admin: gate.admin,
    });
    return adminJsonResponse({ user });
  } catch (error) {
    if (error instanceof AdminUserNotFoundError) {
      return adminJsonResponse({ error: "user_not_found" }, 404);
    }
    if (error instanceof AdminGrantConflictError) {
      return adminJsonResponse({ error: "mutation_in_progress" }, 409);
    }
    throw error;
  }
}

// Pending grants live in Postgres; a deployment without a database, or one
// that has not run the admin_plan_grants migration yet, still serves user and
// team search.
async function listPendingEmailGrantsSafely(query: string) {
  try {
    return await listPendingEmailGrants(query);
  } catch (error) {
    if (error instanceof Error && /DATABASE_URL is required/.test(error.message)) return [];
    if (isMissingGrantsTableError(error)) {
      console.error("admin.pending_grants.table_missing", { hint: "run the admin_plan_grants migration" });
      return [];
    }
    throw error;
  }
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
