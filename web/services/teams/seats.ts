import { billingPlanIdFromMetadata } from "../billing/teamResolution";
import { MAX_PLAN_ID, PRO_PLAN_ID } from "../billing/pro";
import type { TeamAccess } from "./access";
import { TeamApiError } from "./errors";

/**
 * Members a personal-plan team may hold, the owner included. Pro and Max are
 * priced per person but the pool they buy is shared by the whole team, so a
 * small fixed roster keeps a personal plan from turning into a team plan.
 * Team subscriptions keep soft seats (see docs/team-settings-and-invites.md).
 */
export const PERSONAL_PLAN_MEMBER_LIMIT = 3;

/** The roster cap for `team`, or `null` when membership is not capped. */
export function memberLimitForTeam(team: Pick<TeamAccess["team"], "clientReadOnlyMetadata">): number | null {
  const planId = billingPlanIdFromMetadata(team.clientReadOnlyMetadata);
  return planId === PRO_PLAN_ID || planId === MAX_PLAN_ID ? PERSONAL_PLAN_MEMBER_LIMIT : null;
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
      `This plan includes ${limit} members. Remove a member or pending invitation, or upgrade to Team.`,
    );
  }
}
