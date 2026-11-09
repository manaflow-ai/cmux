import { NextRequest } from "next/server";

import {
  ADMIN_TEAM_NAME_MAX_LENGTH,
  AdminCustomTeamError,
  adminCreateTeam,
} from "../../../../../services/admin/customTeams";
import { auditRequestId, withAdminAudit } from "../../../../../services/admin/auditLog";
import { adminJsonResponse, readJsonBody, requireAdmin } from "../../../../../services/admin/routeAuth";
import { enforceBrowserMutationProtection } from "../../../../../services/vms/routeHelpers";

/** POST /api/admin/teams/create { owner: email or user id, displayName } — a team for a custom plan. */
export async function POST(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const parsed = parseCreateBody(await readJsonBody(request));
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "team_create",
      targetKind: "team",
      targetId: null,
      details: parsed ?? null,
      requestId: auditRequestId(request),
    },
    async () => {
      if (!parsed) return adminJsonResponse({ error: "invalid_body" }, 400);
      try {
        return adminJsonResponse({ team: await adminCreateTeam(parsed) });
      } catch (error) {
        if (error instanceof AdminCustomTeamError) return adminJsonResponse({ error: error.code }, error.status);
        throw error;
      }
    },
  );
}

function parseCreateBody(body: unknown): { owner: string; displayName: string } | null {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const { owner, displayName } = body as { owner?: unknown; displayName?: unknown };
  if (typeof owner !== "string" || !owner.trim() || owner.length > 320) return null;
  if (typeof displayName !== "string") return null;
  const name = displayName.trim();
  if (!name || name.length > ADMIN_TEAM_NAME_MAX_LENGTH) return null;
  return { owner: owner.trim(), displayName: name };
}
