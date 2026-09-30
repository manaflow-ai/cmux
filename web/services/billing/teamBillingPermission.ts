/**
 * Team billing (cancel, resume, and the shared Stripe customer portal) is a
 * team administration power, not a membership right: the portal can cancel
 * the subscription, change the payment method, and read invoices for every
 * seat. Stack's `$update_team` permission is the team-administration
 * capability; `team_admin` (and so every team creator) holds it by default,
 * while plain `team_member` does not.
 */
export const TEAM_BILLING_PERMISSION = "$update_team";

type TeamPermissionUser = {
  readonly hasPermission?: (
    scope: { readonly id: string },
    permissionId: string,
  ) => Promise<boolean>;
};

/** Whether this Stack user may change billing for the given team. */
export async function canManageTeamBilling(user: unknown, teamId: string): Promise<boolean> {
  const candidate = user as TeamPermissionUser | null;
  if (typeof candidate?.hasPermission !== "function") return false;
  // Stack resolves a team scope by its id alone, so the resolved billing team
  // id is enough; no second team lookup is needed.
  return await candidate.hasPermission({ id: teamId }, TEAM_BILLING_PERMISSION);
}
