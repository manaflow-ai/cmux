export type BillingTeamLike = {
  readonly id: string;
  readonly displayName: string | null;
  readonly clientReadOnlyMetadata?: unknown;
};

export type BillingTeamUserLike = {
  readonly selectedTeam?: unknown;
  readonly listTeams?: () => Promise<readonly unknown[]>;
};

export async function resolveBillingTeam(
  user: BillingTeamUserLike,
): Promise<BillingTeamLike | null> {
  const selected = billingTeamFromUnknown(user.selectedTeam);
  if (selected) return selected;

  const teams = typeof user.listTeams === "function"
    ? (await user.listTeams()).map(billingTeamFromUnknown).filter((team): team is BillingTeamLike => !!team)
    : [];

  return resolveBillingTeamFromTeams(teams);
}

export function resolveBillingTeamFromTeams(
  teams: readonly BillingTeamLike[],
): BillingTeamLike | null {
  if (teams.length === 1) return teams[0];
  if (teams.length < 2) return null;

  const paidTeams = teams
    .filter((team) => hasActiveBillingPlan(team.clientReadOnlyMetadata))
    .toSorted((left, right) => compareBillingTeamId(left.id, right.id));
  return paidTeams[0] ?? null;
}

export function billingTeamFromUnknown(value: unknown): BillingTeamLike | null {
  if (!value || typeof value !== "object") return null;
  const id = (value as { id?: unknown }).id;
  if (typeof id !== "string" || !id) return null;
  const displayName = (value as { displayName?: unknown; name?: unknown }).displayName ??
    (value as { name?: unknown }).name;
  return {
    id,
    displayName: typeof displayName === "string" && displayName.trim()
      ? displayName.trim()
      : null,
    clientReadOnlyMetadata: (value as { clientReadOnlyMetadata?: unknown }).clientReadOnlyMetadata,
  };
}

export function billingPlanIdFromMetadata(metadata: unknown): string | null {
  if (!metadata || typeof metadata !== "object") return null;
  const value = (metadata as { cmuxVmPlan?: unknown }).cmuxVmPlan ??
    (metadata as { cmuxPlan?: unknown }).cmuxPlan;
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function hasActiveBillingPlan(metadata: unknown): boolean {
  const planId = billingPlanIdFromMetadata(metadata);
  return !!planId && planId !== "free";
}

function compareBillingTeamId(left: string, right: string): number {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}
