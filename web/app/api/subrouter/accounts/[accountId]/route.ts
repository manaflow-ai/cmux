import { cloudDb } from "../../../../../db/client";
import {
  browserMutationOriginAllowed,
  jsonResponse,
  parseBearer,
  requestedVmTeamIdFromRequest,
  requiresBrowserMutationProtection,
} from "../../../../../services/vms/routeHelpers";
import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../../../../../services/vms/auth";
import {
  createSubrouterClient,
  subrouterRuntimeConfig,
  SubrouterClientError,
  SubrouterNotConfiguredError,
} from "../../../../../services/subrouter/client";
import { SubrouterTenantKeySecretError } from "../../../../../services/subrouter/crypto";
import { getOrCreateTenantForTeam } from "../../../../../services/subrouter/tenants";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type RouteContext = {
  params: Promise<{ accountId: string }>;
};

type TeamResolution =
  | { ok: true; teamId: string; teamName: string }
  | { ok: false; response: Response };

export async function DELETE(request: Request, context: RouteContext): Promise<Response> {
  const { accountId } = await context.params;
  const normalizedAccountId = accountId.trim();
  if (!normalizedAccountId || normalizedAccountId.length > 200) {
    return jsonResponse({ error: "invalid_request" }, 400);
  }

  const requestedTeamId = requestedVmTeamIdFromRequest(request);
  const user = await verifyRequest(request, {
    requestedTeamId,
    allowCookie: true,
  });
  if (!user) return unauthorized();
  const bearer = parseBearer(request);
  if (requiresBrowserMutationProtection(request.method, bearer) && !browserMutationOriginAllowed(request)) {
    return jsonResponse({ error: "forbidden" }, 403);
  }

  const team = resolveTeam(request, user);
  if (!team.ok) return team.response;

  const config = subrouterRuntimeConfig();
  if (!config) return jsonResponse({ error: "subrouter not configured" }, 503);
  const client = createSubrouterClient({
    baseUrl: config.baseUrl,
    adminToken: config.adminToken,
  });

  try {
    const tenant = await getOrCreateTenantForTeam(
      cloudDb(),
      team.teamId,
      team.teamName,
      {
        client,
        tenantKeySecret: config.tenantKeySecret,
      },
    );
    await client.deleteAccount(tenant.tenantKey, normalizedAccountId);
    return jsonResponse({ ok: true, teamId: team.teamId });
  } catch (err) {
    return subrouterErrorResponse(err);
  }
}

function resolveTeam(request: Request, user: AuthedUser): TeamResolution {
  const requested = requestedVmTeamIdFromRequest(request);
  if (requested) {
    const isMember = user.teamIds.includes(requested) || requested === user.id;
    if (!isMember) {
      return {
        ok: false,
        response: jsonResponse({ error: "team_not_found" }, 403),
      };
    }
    return {
      ok: true,
      teamId: requested,
      teamName: teamDisplayName(user, requested),
    };
  }

  const teamId = user.selectedTeamId ?? user.billingTeamId;
  return {
    ok: true,
    teamId,
    teamName: teamDisplayName(user, teamId),
  };
}

function teamDisplayName(user: AuthedUser, teamId: string): string {
  if (teamId === user.id) {
    return user.displayName ?? user.primaryEmail ?? user.id;
  }
  const team = user.teams.find((candidate) => candidate.id === teamId);
  return team?.displayName ?? teamId;
}

function subrouterErrorResponse(err: unknown): Response {
  if (err instanceof SubrouterNotConfiguredError || err instanceof SubrouterTenantKeySecretError) {
    return jsonResponse({ error: "subrouter not configured" }, 503);
  }
  if (err instanceof SubrouterClientError) {
    const status = err.status !== null && err.status >= 400 && err.status < 500
      ? err.status
      : 502;
    return jsonResponse({ error: "subrouter_request_failed" }, status);
  }
  return jsonResponse({ error: "subrouter_request_failed" }, 500);
}
