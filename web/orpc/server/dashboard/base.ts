import { os as baseOS } from "@orpc/server";
import { resolveDashboardSessionUser } from "@/services/billing/dashboardSessionRoute";
import { requireTeamAccess, type TeamAccess, type TeamAccessOptions } from "@/services/teams/access";
import { authenticateTeamRequest } from "@/services/teams/http";
import { enforceTeamRateLimit } from "@/services/teams/rateLimit";
import type { AuthedUser } from "@/services/vms/auth";
import { browserMutationOriginAllowed } from "@/services/vms/routeHelpers";
import { DASHBOARD_ERRORS, dashboardRefusal, refusalFromResponse, TEAM_ERRORS, teamRefusalFromError } from "./errors";

/**
 * Context of one dashboard procedure call. `request` is the browser's RPC
 * request, or for the page's server prefetch a GET built from the incoming
 * page request's headers (`serverPrefetch`).
 */
export type DashboardContext = {
  readonly request: Request;
  readonly serverPrefetch?: boolean;
};

export const dashboardOS = baseOS.$context<DashboardContext>().errors(DASHBOARD_ERRORS);

/**
 * Every browser call is a POST carrying the session cookie, so it must come
 * from an allowed origin, as the REST mutations require. The server prefetch
 * never leaves the page request, so it has no origin to check.
 */
export const requireDashboardOrigin = dashboardOS.middleware(async ({ context, next }) => {
  if (!context.serverPrefetch && !browserMutationOriginAllowed(context.request)) {
    throw dashboardRefusal(403, "forbidden");
  }
  return next();
});

/** The signed-in browser user; the same resolver the session route used. */
export const requireDashboardUser = dashboardOS.middleware(async ({ context, next }) => {
  const session = await resolveDashboardSessionUser(context.request);
  if (!session.ok) throw dashboardRefusal(session.status, session.reason);
  return next({ context: { user: session.user } });
});

/** Base for dashboard reads and writes that need only a signed-in user. */
export const authed = dashboardOS.use(requireDashboardOrigin).use(requireDashboardUser);

/**
 * Team procedures authenticate exactly like the `/api/teams` routes
 * (cookie or native bearer, browser origin check) and narrow error reasons to
 * the team vocabulary. Service refusals map the same way `runTeamRoute` maps
 * them.
 */
const teamOS = baseOS.$context<DashboardContext>().errors(TEAM_ERRORS);

const teamServiceErrors = teamOS.middleware(async ({ next }) => {
  try {
    return await next();
  } catch (error) {
    throw teamRefusalFromError(error);
  }
});

const requireTeamUser = teamOS.middleware(async ({ context, next }) => {
  const auth = await authenticateTeamRequest(context.request);
  if (!auth.ok) throw await refusalFromResponse(auth.response);
  return next({ context: { user: auth.user } });
});

export const teamUser = teamOS.use(teamServiceErrors).use(requireTeamUser);

/** Middleware that runs after `requireTeamUser` and reads its user. */
const afterTeamUser = baseOS.$context<DashboardContext & { readonly user: AuthedUser }>();

/** The invite rate limit of the create, invite, link, join, and accept routes. */
export function teamRateLimit(route: string) {
  return afterTeamUser.middleware(async ({ context, next }) => {
    const limited = await enforceTeamRateLimit({ request: context.request, route, userId: context.user.id });
    if (limited) throw await refusalFromResponse(limited);
    return next();
  });
}

/**
 * Verified membership of the team named by the procedure input, with the
 * viewer's role and permissions in `context.team`. A non-member and a missing
 * team get the same refusal, as on the REST routes.
 */
export function teamAccess(options: Omit<TeamAccessOptions, "stack"> = {}) {
  return afterTeamUser.middleware(async ({ context, next }, input: { readonly teamId: string }) => {
    const result = await requireTeamAccess(context.user, input.teamId, options);
    if (!result.ok) throw dashboardRefusal(result.refusal.status, result.refusal.code);
    return next({ context: { team: result.access satisfies TeamAccess } });
  });
}
