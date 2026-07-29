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

export type AuthorizedSubrouterTeam = {
  readonly teamId: string;
  readonly teamName: string;
  readonly use: boolean;
  readonly manageAccounts: boolean;
  readonly personal: boolean;
};

export async function resolveTeam(
  request: Request,
  user: AuthedUser,
): Promise<TeamResolution> {
  const requested = requestedVmTeamIdFromRequest(request);
  let teamId: string;
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
    teamId = requested;
  } else {
    teamId = user.selectedTeamId ?? user.billingTeamId;
    if (!subrouterTeamAllowed(teamId)) {
      return {
        ok: false,
        response: jsonResponse({ error: "team_not_allowed" }, 403),
      };
    }
  }

  const permissions = await user.resolveSubrouterPermissions(teamId);
  return {
    ok: true,
    teamId,
    teamName: teamDisplayName(user, teamId),
    ...permissions,
  };
}

// Resolve team permissions only for Subrouter callers. This is intentionally
// sequential so a large Stack team list cannot fan out permission API calls
// through shared authentication.
export async function authorizedSubrouterTeams(
  user: AuthedUser,
): Promise<readonly AuthorizedSubrouterTeam[]> {
  const candidates = [
    ...user.teams.map((team) => ({
      teamId: team.id,
      teamName: team.displayName ?? team.id,
      personal: false,
    })),
    {
      teamId: user.id,
      teamName: user.displayName ?? user.primaryEmail ?? user.id,
      personal: true,
    },
  ];
  const teams: AuthorizedSubrouterTeam[] = [];
  const seen = new Set<string>();
  for (const candidate of candidates) {
    if (
      seen.has(candidate.teamId) ||
      !subrouterTeamAllowed(candidate.teamId)
    ) {
      continue;
    }
    seen.add(candidate.teamId);
    const permissions = await user.resolveSubrouterPermissions(
      candidate.teamId,
    );
    if (!permissions.use && !permissions.manageAccounts) continue;
    teams.push({ ...candidate, ...permissions });
  }
  return teams;
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
    console.error("Subrouter control-plane configuration failed", {
      errorType: err.name,
    });
    return serviceUnavailableResponse();
  }
  if (err instanceof SubrouterClientError) {
    console.error("Subrouter upstream request failed", {
      operation: err.operation,
      status: err.status,
    });
    const status = err.status !== null && err.status >= 400 && err.status < 500
      ? err.status
      : 502;
    return jsonResponse({ error: "upstream_request_failed" }, status);
  }
  console.error("Subrouter control-plane request failed", {
    errorType: err instanceof Error ? err.name : typeof err,
  });
  return jsonResponse({ error: "upstream_request_failed" }, 500);
}
