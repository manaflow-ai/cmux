import { NextRequest } from "next/server";

import {
  AdminGrantConflictError,
  AdminTeamNotFoundError,
  loadAdminTeam,
  setTeamVmEntitlementOverride,
} from "../../../../../services/admin/proGrants";
import { auditRequestId, withAdminAudit } from "../../../../../services/admin/auditLog";
import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
} from "../../../../../services/admin/routeAuth";
import {
  validateVmEntitlementOverride,
  type VmEntitlementOverride,
} from "../../../../../services/vms/entitlementOverride";
import { enforceBrowserMutationProtection } from "../../../../../services/vms/routeHelpers";

const MAX_TEAM_ID_LENGTH = 200;

/** GET /api/admin/teams/entitlements?teamId= — one team's row, including its custom Cloud VM deal. */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const teamId = (request.nextUrl.searchParams.get("teamId") ?? "").trim();
  if (!teamId || teamId.length > MAX_TEAM_ID_LENGTH) {
    return adminJsonResponse({ error: "invalid_query" }, 400);
  }
  const team = await loadAdminTeam(teamId);
  return team ? adminJsonResponse({ team }) : adminJsonResponse({ error: "team_not_found" }, 404);
}

/**
 * POST /api/admin/teams/entitlements { teamId, override }
 *
 * `override` is `{ maxActiveVms?, poolVcpus?, poolMemoryMb?, maxMemoryMb?,
 * planLabel?, monthlyPriceCents? }`, or null to return the team to its plan
 * defaults. Missing fields keep the plan default.
 */
export async function POST(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const parsed = parseOverrideBody(await readJsonBody(request));
  // Audited from here on: a malformed body from an admin is still recorded.
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "team_entitlement_override_set",
      targetKind: "team",
      targetId: parsed.ok ? parsed.teamId : parsed.teamId ?? null,
      details: parsed.ok ? { override: parsed.override } : { error: parsed.error },
      requestId: auditRequestId(request),
    },
    async () => {
      if (!parsed.ok) return adminJsonResponse({ error: "invalid_body", detail: parsed.error }, 400);
      return await applyOverride(parsed.teamId, parsed.override, gate.admin);
    },
  );
}

type ParsedOverrideBody =
  | { readonly ok: true; readonly teamId: string; readonly override: VmEntitlementOverride | null }
  | { readonly ok: false; readonly teamId?: string; readonly error: string };

function parseOverrideBody(body: unknown): ParsedOverrideBody {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { ok: false, error: "body must be an object" };
  const { teamId, override } = body as { teamId?: unknown; override?: unknown };
  if (typeof teamId !== "string" || !teamId.trim() || teamId.length > MAX_TEAM_ID_LENGTH) {
    return { ok: false, error: "teamId is required" };
  }
  if (override === undefined) return { ok: false, teamId: teamId.trim(), error: "override is required (null clears it)" };
  const validated = validateVmEntitlementOverride(override);
  if (!validated.ok) return { ok: false, teamId: teamId.trim(), error: `${validated.field} ${validated.message}` };
  return { ok: true, teamId: teamId.trim(), override: validated.override };
}

async function applyOverride(
  teamId: string,
  override: VmEntitlementOverride | null,
  admin: { id: string; primaryEmail: string | null },
): Promise<Response> {
  try {
    const team = await setTeamVmEntitlementOverride({ teamId, override, admin });
    return adminJsonResponse({ team });
  } catch (error) {
    if (error instanceof AdminTeamNotFoundError) {
      return adminJsonResponse({ error: "team_not_found" }, 404);
    }
    if (error instanceof AdminGrantConflictError) {
      return adminJsonResponse({ error: "mutation_in_progress" }, 409);
    }
    throw error;
  }
}
