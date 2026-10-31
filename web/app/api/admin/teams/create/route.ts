import { NextRequest } from "next/server";

import { auditRequestId, withAdminAudit } from "../../../../../services/admin/auditLog";
import {
  AdminTeamOwnerNotFoundError,
  createTeamForCustomer,
} from "../../../../../services/admin/teamEntitlements";
import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
} from "../../../../../services/admin/routeAuth";
import { enforceBrowserMutationProtection } from "../../../../../services/vms/routeHelpers";

const MAX_TEAM_NAME_LENGTH = 120;

/** POST /api/admin/teams/create { displayName, ownerUserId } — a team for a customer deal. */
export async function POST(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const parsed = parseBody(await readJsonBody(request));
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "team_create",
      targetKind: "user",
      targetId: parsed?.ownerUserId ?? null,
      details: parsed ? { displayName: parsed.displayName } : null,
      requestId: auditRequestId(request),
    },
    async () => {
      if (!parsed) return adminJsonResponse({ error: "invalid_body" }, 400);
      try {
        const team = await createTeamForCustomer(parsed);
        return adminJsonResponse({ team }, 201);
      } catch (error) {
        if (error instanceof AdminTeamOwnerNotFoundError) return adminJsonResponse({ error: "owner_not_found" }, 404);
        throw error;
      }
    },
  );
}

function parseBody(body: unknown): { displayName: string; ownerUserId: string } | null {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const { displayName, ownerUserId } = body as { displayName?: unknown; ownerUserId?: unknown };
  if (typeof displayName !== "string" || typeof ownerUserId !== "string") return null;
  const name = displayName.trim();
  const owner = ownerUserId.trim();
  if (!name || name.length > MAX_TEAM_NAME_LENGTH || !owner) return null;
  return { displayName: name, ownerUserId: owner };
}
