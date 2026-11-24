import { NextRequest } from "next/server";

import {
  ADMIN_USER_SEARCH_MIN_QUERY_LENGTH,
  AdminGrantConflictError,
  AdminUserNotFoundError,
  type AdminGrantSlot,
  isAdminGrantSlot,
  isAdminGrantablePlanId,
  isMissingGrantsTableError,
  type AdminGrantablePlanId,
  listPendingEmailGrants,
  searchAdminTeams,
  searchAdminUsers,
  resolveGrantSlot,
  setManualPlanGrant,
} from "../../../../services/admin/proGrants";
import { auditRequestId, withAdminAudit } from "../../../../services/admin/auditLog";
import { isValidScanCursor } from "../../../../services/admin/proList";
import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
} from "../../../../services/admin/routeAuth";
import { enforceBrowserMutationProtection } from "../../../../services/vms/routeHelpers";

const MAX_QUERY_LENGTH = 200;

/**
 * GET /api/admin/users?q=<email, name, or id>[&teamsCursor=<cursor>][&showTestTeams=1]
 * — users, one page of teams, and pending email grants. Empty probe teams are
 * left out of `teams` unless showTestTeams=1; `hiddenTestTeams` counts them,
 * and `teamsNextCursor` (when set) fetches the next page of teams.
 */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const params = request.nextUrl.searchParams;
  const query = (params.get("q") ?? "").trim();
  if (query.length < ADMIN_USER_SEARCH_MIN_QUERY_LENGTH || query.length > MAX_QUERY_LENGTH) {
    return adminJsonResponse({ error: "invalid_query" }, 400);
  }
  const teamsCursor = params.get("teamsCursor");
  if (teamsCursor !== null && !isValidScanCursor(teamsCursor)) {
    return adminJsonResponse({ error: "invalid_cursor" }, 400);
  }
  const includeTestTeams = params.get("showTestTeams") === "1";
  const [users, teamPage, pendingGrants] = await Promise.all([
    searchAdminUsers(query),
    searchAdminTeams(query, { cursor: teamsCursor, includeTestTeams }),
    listPendingEmailGrantsSafely(query),
  ]);
  return adminJsonResponse({
    users,
    teams: teamPage.teams,
    teamsNextCursor: teamPage.nextCursor,
    hiddenTestTeams: teamPage.hiddenTestTeams,
    pendingGrants,
  });
}

/**
 * POST /api/admin/users { userId, plan: "pro" | "max" | "founders" | "next_plus" | "next_pro" | "next_max" | null, slot?: "classic" | "next" }
 *
 * An account holds a classic grant and a cmux NEXT grant side by side. A NEXT
 * plan always writes the NEXT slot; a classic plan writes the classic slot.
 * `plan: null` removes the grant of `slot` (absent: the classic slot).
 * `slot: "next"` with a classic plan is refused with 400.
 */
export async function POST(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const parsed = parseGrantBody(await readJsonBody(request));
  // Audited from here on: a malformed body from an admin is still recorded.
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "user_grant_set",
      targetKind: "user",
      targetId: parsed?.userId ?? null,
      details: parsed ? { plan: parsed.plan, slot: parsed.slot } : null,
      requestId: auditRequestId(request),
    },
    async () => {
      if (!parsed) return adminJsonResponse({ error: "invalid_body" }, 400);
      if (parsed.slot === null) return adminJsonResponse({ error: "slot_plan_mismatch" }, 400);
      return applyUserGrant({ ...parsed, slot: parsed.slot }, gate.admin);
    },
  );
}

async function applyUserGrant(
  parsed: { userId: string; plan: AdminGrantablePlanId | null; slot: AdminGrantSlot },
  admin: { id: string; primaryEmail: string | null },
): Promise<Response> {
  try {
    const user = await setManualPlanGrant({
      targetUserId: parsed.userId,
      plan: parsed.plan,
      slot: parsed.slot,
      admin,
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

/**
 * The grant request, or null for a malformed body. `slot` is the resolved
 * slot, or null when `slot: "next"` names a classic plan.
 */
function parseGrantBody(
  body: unknown,
): { userId: string; plan: AdminGrantablePlanId | null; slot: AdminGrantSlot | null } | null {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const { userId, plan, slot } = body as { userId?: unknown; plan?: unknown; slot?: unknown };
  if (typeof userId !== "string" || !userId.trim()) return null;
  if (slot !== undefined && !isAdminGrantSlot(slot)) return null;
  if (plan !== null && !isAdminGrantablePlanId(plan)) return null;
  let resolved: AdminGrantSlot | null;
  try {
    resolved = resolveGrantSlot(plan, slot);
  } catch {
    resolved = null;
  }
  return { userId: userId.trim(), plan, slot: resolved };
}
