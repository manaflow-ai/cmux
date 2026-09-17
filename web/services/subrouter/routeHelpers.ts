import {
  jsonResponse,
  requestedVmTeamIdFromRequest,
} from "../vms/routeHelpers";
import {
  subrouterAllowedTeamIds,
  type AuthedUser,
} from "../vms/auth";
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

export function normalizeAccountId(raw: string): string | null {
  const accountId = raw.trim();
  return accountId && accountId.length <= 200 ? accountId : null;
}

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
    if (!user.selectedTeamId) {
      return {
        ok: false,
        response: jsonResponse({ error: "team_selection_required" }, 409),
      };
    }
    teamId = user.selectedTeamId;
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

const SUBROUTER_PERMISSION_CONCURRENCY = 8;

// Resolve team permissions only for Subrouter callers. A small worker pool
// avoids serial Stack round trips without creating unbounded request fanout.
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
  const seen = new Set<string>();
  const uniqueCandidates = candidates.filter((candidate) => {
    if (
      seen.has(candidate.teamId) ||
      !subrouterTeamAllowed(candidate.teamId)
    ) {
      return false;
    }
    seen.add(candidate.teamId);
    return true;
  });
  const resolved = await mapWithConcurrency(
    uniqueCandidates,
    SUBROUTER_PERMISSION_CONCURRENCY,
    async (candidate) => {
      const permissions = await user.resolveSubrouterPermissions(
        candidate.teamId,
      );
      if (
        (!permissions.use && !permissions.manageAccounts)
      ) {
        return null;
      }
      return { ...candidate, ...permissions };
    },
  );
  return resolved.filter(
    (team): team is AuthorizedSubrouterTeam => team !== null,
  );
}

async function mapWithConcurrency<T, U>(
  values: readonly T[],
  concurrency: number,
  transform: (value: T) => Promise<U>,
): Promise<readonly U[]> {
  const results = new Array<U>(values.length);
  let nextIndex = 0;
  const worker = async () => {
    while (true) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= values.length) return;
      results[index] = await transform(values[index]);
    }
  };
  await Promise.all(
    Array.from(
      { length: Math.min(concurrency, values.length) },
      () => worker(),
    ),
  );
  return results;
}

export function subrouterTeamAllowed(
  teamId: string,
  raw = process.env.SUBROUTER_ALLOWED_TEAM_IDS,
): boolean {
  const allowed = subrouterAllowedTeamIds(raw);
  return allowed === "*" || allowed.has(teamId);
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
