// A team's enterprise deal as its own members see it on the billing page: the
// plan name (the deal's label, default "Enterprise") and the Cloud VM limits
// the deal gives. The agreed monthly price is shown to team admins only; the
// label and price live in server-only team metadata, so they are read here on
// the server and never from the member's client.

import { defaultAdminStackApp, type AdminStackApp } from "../admin/proGrants";
import { teamEntitlementsView, type TeamDealSource } from "../admin/teamEntitlements";
import { withStackDeadline } from "../teams/stack";

export const DEFAULT_ENTERPRISE_PLAN_LABEL = "Enterprise";

export type TeamEnterpriseDeal = {
  /** The deal's plan name, e.g. "Enterprise". */
  readonly label: string;
  /** Agreed monthly price in US dollars; null when none is recorded or the viewer is not a team admin. */
  readonly monthlyPriceUsd: number | null;
  /** Saved machines for the whole team; null means no limit. */
  readonly maxActiveVms: number | null;
  /** vCPUs and memory the team's running machines share; null means no limit. */
  readonly poolVcpus: number | null;
  readonly poolMemoryMb: number | null;
  /** The largest machine any member may start. */
  readonly maxMemoryMb: number;
  readonly maxVcpus: number;
};

/**
 * The deal for a team on a plan that honors it (paid, not Plus), or null when
 * the team has no deal or its plan ignores the deal.
 */
export function teamEnterpriseDeal(
  team: TeamDealSource,
  viewer: { readonly canManageBilling: boolean },
): TeamEnterpriseDeal | null {
  const view = teamEntitlementsView(team);
  if (!view.override || !view.planHonorsOverride) return null;
  const { effective, override } = view;
  return {
    label: override.planLabel ?? DEFAULT_ENTERPRISE_PLAN_LABEL,
    monthlyPriceUsd: viewer.canManageBilling && override.monthlyPriceCents !== null ? override.monthlyPriceCents / 100 : null,
    maxActiveVms: effective.maxActiveVms,
    poolVcpus: effective.poolVcpus,
    poolMemoryMb: effective.poolMemoryMb,
    maxMemoryMb: effective.maxMemoryMb,
    maxVcpus: effective.maxVcpus,
  };
}

/**
 * Load the deal for the member's team. When that team object lacks server
 * metadata, fetch the server's view under the Stack deadline. A Stack failure
 * or timeout leaves the billing page on its plain Team view.
 */
export async function loadTeamEnterpriseDeal(
  memberTeam: TeamDealSource,
  viewer: { readonly canManageBilling: boolean },
  app: Pick<AdminStackApp, "getTeam"> = defaultAdminStackApp(),
): Promise<TeamEnterpriseDeal | null> {
  // A free or Plus team ignores any deal: skip the Stack call.
  if (!teamEntitlementsView(memberTeam).planHonorsOverride) return null;
  // The server app's team already carries server metadata; read it directly.
  if (memberTeam.serverMetadata !== undefined) return teamEnterpriseDeal(memberTeam, viewer);
  const teamId = memberTeam.id;
  try {
    const team = await withStackDeadline(() => app.getTeam(teamId));
    if (!team || team.id !== teamId) return null;
    return teamEnterpriseDeal(team, viewer);
  } catch (error) {
    console.error("team enterprise deal unavailable", { teamId, error: error instanceof Error ? error.name : "unknown" });
    return null;
  }
}
