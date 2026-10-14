import { billingPlanIdFromMetadata } from "../billing/teamResolution";
import { TEAM_PLAN_ID } from "../billing/pro";
import type { TeamAccess } from "./access";
import { TeamApiError } from "./errors";

/**
 * Members a team without the Team plan may hold, the owner and pending
 * invitations included. Pro and Max are priced per person but the pool they
 * buy is shared by the whole team, and a free team must not grow into an
 * organization without paying for one, so a small fixed roster keeps either
 * from turning into a Team plan. Team subscriptions have no cap: their Stripe
 * quantity follows the member count (services/billing/teamSeats.ts).
 */
export const PERSONAL_PLAN_MEMBER_LIMIT = 3;

/** The roster cap for `team`, or `null` when membership is not capped. */
export function memberLimitForTeam(team: Pick<TeamAccess["team"], "clientReadOnlyMetadata">): number | null {
  return hasTeamPlan(team.clientReadOnlyMetadata) ? null : PERSONAL_PLAN_MEMBER_LIMIT;
}

/** A Team subscription (`cmuxPlan`) or an operator Team grant (`cmuxVmPlan`). */
function hasTeamPlan(metadata: unknown): boolean {
  const subscribed = metadata && typeof metadata === "object"
    ? (metadata as { cmuxPlan?: unknown }).cmuxPlan
    : undefined;
  return subscribed === TEAM_PLAN_ID || billingPlanIdFromMetadata(metadata) === TEAM_PLAN_ID;
}

/**
 * Refuse when `occupied` seats (members plus pending invitations) leave no
 * room for `adding` more. Pending invitations hold a seat so two admins
 * cannot both fill the last one.
 */
export function assertSeatsAvailable(input: {
  readonly team: Pick<TeamAccess["team"], "clientReadOnlyMetadata">;
  readonly occupied: number;
  readonly adding: number;
}): void {
  const limit = memberLimitForTeam(input.team);
  if (limit === null) return;
  if (input.occupied + input.adding > limit) {
    throw new TeamApiError(
      "seat_limit",
      409,
      `Teams without the Team plan include ${limit} members. Remove a member or pending invitation, or upgrade to Team.`,
    );
  }
}
