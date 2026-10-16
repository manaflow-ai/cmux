import { Effect } from "effect";

import type { AuthedUser } from "../vms/auth";
import {
  authorizedSubrouterTeams,
  type AuthorizedSubrouterTeam,
} from "../subrouter/routeHelpers";
import {
  teamBillingRoleOrMember,
  type TeamBillingAccessUser,
  type TeamBillingRole,
} from "./teamBillingAccess";

/** Per-team billing fields the dashboard team catalog carries. */
export type TeamCatalogBilling = {
  readonly planId: string | null;
  readonly seats: number | null;
  readonly role: TeamBillingRole;
  readonly canManageBilling: boolean;
};

export type BillingCatalogTeam = AuthorizedSubrouterTeam & TeamCatalogBilling;

type LoadStackUser = (userId: string) => Promise<TeamBillingAccessUser | null>;

/**
 * The subrouter team catalog plus plan, seats and billing role per team. The
 * personal entry is always the user's own admin scope with the personal plan.
 * Roles come from Stack `team_admin`; if Stack cannot answer, a team reads as
 * "member" so a read-only listing never fails and never over-grants. Every
 * mutation re-authorizes through resolveTeamBillingAccess.
 */
export async function billingCatalogTeams(
  user: AuthedUser,
  loadStackUser: LoadStackUser,
): Promise<readonly BillingCatalogTeam[]> {
  const teams = authorizedSubrouterTeams(user);
  const teamIds = teams.filter((team) => !team.personal).map((team) => team.teamId);
  const adminTeamIds = teamIds.length > 0
    ? await adminTeamIdsWithinBudget(user.id, teamIds, loadStackUser)
    : new Set<string>();
  return teams.map((team): BillingCatalogTeam => {
    if (team.personal) {
      return { ...team, planId: user.userBillingPlanId, seats: null, role: "admin", canManageBilling: true };
    }
    const authed = user.teams.find((candidate) => candidate.id === team.teamId);
    const role: TeamBillingRole = adminTeamIds.has(team.teamId) ? "admin" : "member";
    return {
      ...team,
      planId: authed?.billingPlanId ?? null,
      seats: authed?.billingSeats ?? null,
      role,
      canManageBilling: role === "admin",
    };
  });
}

/**
 * Stays well inside the subrouter authorization deadline that wraps the
 * catalog request, so a slow Stack answer degrades roles instead of 503ing.
 */
const ROLE_LOOKUP_BUDGET = "3 seconds";

async function adminTeamIdsWithinBudget(
  userId: string,
  teamIds: readonly string[],
  loadStackUser: LoadStackUser,
): Promise<ReadonlySet<string>> {
  const result = await Effect.runPromise(Effect.tryPromise(async () => {
    const stackUser = await loadStackUser(userId);
    if (!stackUser || typeof stackUser.listTeams !== "function") return new Set<string>();
    const stackTeams = await stackUser.listTeams();
    const wanted = new Set(teamIds);
    const roles = await Promise.all(stackTeams
      .filter((team) => wanted.has(team.id))
      .map(async (team) => [team.id, await teamBillingRoleOrMember(stackUser, team)] as const));
    return new Set(roles.filter(([, role]) => role === "admin").map(([id]) => id));
  }).pipe(Effect.timeout(ROLE_LOOKUP_BUDGET), Effect.either));
  return result._tag === "Right" ? result.right : new Set<string>();
}
