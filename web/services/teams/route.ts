import type { AuthedUser } from "../vms/auth";
import { jsonResponse } from "../vms/routeHelpers";
import { requireTeamAccess, type TeamAccess, type TeamAccessOptions } from "./access";
import { authenticateTeamRequest, runTeamRoute, type TeamRouteDependencies } from "./http";
import { enforceTeamRateLimit } from "./rateLimit";

export type TeamRouteParams = Promise<{ teamId: string }>;

export type UserRouteOptions = TeamRouteDependencies & {
  /** Apply the team invite rate limit after authentication. */
  readonly rateLimited?: boolean;
};

/** Authenticate (and optionally rate limit) a team route that is not scoped to one team. */
export async function withTeamUserRoute(
  request: Request,
  route: string,
  options: UserRouteOptions,
  handler: (user: AuthedUser) => Promise<Response>,
): Promise<Response> {
  return runTeamRoute(route, async () => {
    const auth = await authenticateTeamRequest(request, options);
    if (!auth.ok) return auth.response;
    if (options.rateLimited) {
      const limited = await enforceTeamRateLimit({ request, route, userId: auth.user.id });
      if (limited) return limited;
    }
    return handler(auth.user);
  });
}

/** `withTeamUserRoute` plus `requireTeamAccess` for `/api/teams/[teamId]/...`. */
export async function withTeamAccessRoute(
  request: Request,
  route: string,
  teamId: string,
  options: UserRouteOptions & Omit<TeamAccessOptions, "stack">,
  handler: (access: TeamAccess, user: AuthedUser) => Promise<Response>,
): Promise<Response> {
  return withTeamUserRoute(request, route, options, async (user) => {
    const result = await requireTeamAccess(user, teamId, options);
    if (!result.ok) return result.response;
    return handler(result.access, user);
  });
}

export function teamJson(data: unknown, status = 200): Response {
  return jsonResponse(data, status, { "cache-control": "no-store" });
}

export const TEAM_OK = { ok: true } as const;
