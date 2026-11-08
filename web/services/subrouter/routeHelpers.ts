import {
  jsonResponse,
  requestedVmTeamIdFromRequest,
} from "../vms/routeHelpers";
import type { AuthedUser } from "../vms/auth";
import { HostedSubrouterError } from "./hostedClient";

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

// Access to Subrouter and coderouter is team membership only. Every member of
// a team (and every user in their personal team) may use it and manage its
// accounts; there is no Stack permission, team allow-list, or plan gate. The
// capability fields stay on the wire so hosted tenant exchange and clients
// keep their shape.
const MEMBER_CAPABILITIES = { use: true, manageAccounts: true } as const;

export function normalizeAccountId(raw: string): string | null {
  const accountId = raw.trim();
  return accountId && accountId.length <= 200 ? accountId : null;
}

export function resolveTeam(
  request: Request,
  user: AuthedUser,
): TeamResolution {
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
    teamId = requested;
  } else {
    if (!user.selectedTeamId) {
      return {
        ok: false,
        response: jsonResponse({ error: "team_selection_required" }, 409),
      };
    }
    teamId = user.selectedTeamId;
  }

  return {
    ok: true,
    teamId,
    teamName: teamDisplayName(user, teamId),
    ...MEMBER_CAPABILITIES,
  };
}

/** Every team the user belongs to plus their personal team, each with full capabilities. */
export function authorizedSubrouterTeams(
  user: AuthedUser,
): readonly AuthorizedSubrouterTeam[] {
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
  const seen = new Set<string>();
  return candidates.flatMap((candidate) => {
    if (seen.has(candidate.teamId)) return [];
    seen.add(candidate.teamId);
    return [{ ...candidate, ...MEMBER_CAPABILITIES }];
  });
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
  if (err instanceof HostedSubrouterError) {
    console.error("Subrouter upstream request failed", {
      status: err.status,
      authentication: err.authentication,
    });
    const internalAuthenticationFailure =
      (err.status === 401 || err.status === 403) &&
      err.authentication !== "caller";
    const status = !internalAuthenticationFailure &&
        err.status >= 400 && err.status < 500
      ? err.status
      : 502;
    return jsonResponse({ error: "upstream_request_failed" }, status);
  }
  console.error("Subrouter control-plane request failed", {
    errorType: err instanceof Error ? err.name : typeof err,
  });
  return jsonResponse({ error: "upstream_request_failed" }, 500);
}
