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
  | {
    ok: true;
    teamId: string;
    teamName: string;
    use: boolean;
    manageAccounts: boolean;
  }
  | { ok: false; response: Response };

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
    if (!subrouterTeamAllowed(requested)) {
      return {
        ok: false,
        response: jsonResponse({ error: "team_not_allowed" }, 403),
      };
    }
    const permissions = teamPermissions(user, requested);
    return {
      ok: true,
      teamId: requested,
      teamName: teamDisplayName(user, requested),
      ...permissions,
    };
  }

  const teamId = user.selectedTeamId ?? user.billingTeamId;
  if (!subrouterTeamAllowed(teamId)) {
    return {
      ok: false,
      response: jsonResponse({ error: "team_not_allowed" }, 403),
    };
  }
  return {
    ok: true,
    teamId,
    teamName: teamDisplayName(user, teamId),
    ...teamPermissions(user, teamId),
  };
}

export function subrouterTeamAllowed(
  teamId: string,
  raw = process.env.SUBROUTER_ALLOWED_TEAM_IDS,
): boolean {
  const allowed = raw
    ?.split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  return !allowed?.length || allowed.includes(teamId);
}

function teamPermissions(
  user: AuthedUser,
  teamId: string,
): { readonly use: boolean; readonly manageAccounts: boolean } {
  if (teamId === user.id) {
    return {
      use: user.personalSubrouterUse ?? false,
      manageAccounts: user.personalSubrouterManageAccounts ?? false,
    };
  }
  const team = user.teams.find((candidate) => candidate.id === teamId);
  return {
    use: team?.subrouterUse ?? false,
    manageAccounts: team?.subrouterManageAccounts ?? false,
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
