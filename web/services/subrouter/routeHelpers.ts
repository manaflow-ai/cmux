import {
  jsonResponse,
  requestedVmTeamIdFromRequest,
} from "../vms/routeHelpers";
import type { AuthedUser } from "../vms/auth";
import { SubrouterClientError, SubrouterNotConfiguredError } from "./client";
import {
  SubrouterTenantKeyDecryptionError,
  SubrouterTenantKeySecretError,
} from "./crypto";

export type TeamResolution =
  | { ok: true; teamId: string; teamName: string }
  | { ok: false; response: Response };

// Authorization is membership-based by design: cmux teams are flat today (no
// role system exists anywhere in the web API; Cloud VM create/destroy and
// billing are membership-gated the same way), so any member may manage the
// team's AI accounts. Revisit when team roles land platform-wide.
export function resolveTeam(request: Request, user: AuthedUser): TeamResolution {
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

export function teamDisplayName(user: AuthedUser, teamId: string): string {
  if (teamId === user.id) {
    return user.displayName ?? user.primaryEmail ?? user.id;
  }
  const team = user.teams.find((candidate) => candidate.id === teamId);
  return team?.displayName ?? teamId;
}

export function serviceUnavailableResponse(): Response {
  return jsonResponse({ error: "service_unavailable" }, 503);
}

export function subrouterErrorResponse(err: unknown): Response {
  if (
    err instanceof SubrouterNotConfiguredError ||
    err instanceof SubrouterTenantKeySecretError ||
    err instanceof SubrouterTenantKeyDecryptionError
  ) {
    return serviceUnavailableResponse();
  }
  if (err instanceof SubrouterClientError) {
    const status = err.status !== null && err.status >= 400 && err.status < 500
      ? err.status
      : 502;
    return jsonResponse({ error: "upstream_request_failed" }, status);
  }
  return jsonResponse({ error: "upstream_request_failed" }, 500);
}
