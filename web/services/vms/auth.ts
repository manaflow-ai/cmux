import { getStackServerApp, isStackConfigured } from "../../app/lib/stack";

export type AuthedUser = {
  id: string;
  displayName: string | null;
  primaryEmail: string | null;
  billingCustomerType: "team" | "user";
  billingTeamId: string;
  selectedTeamId: string | null;
  teams: readonly AuthedTeam[];
  teamIds: readonly string[];
  userBillingPlanId: string | null;
  billingPlanId: string | null;
  /** ISO-8601 start of the user's no-card Cloud VM trial, or null. */
  vmTrialStartedAt: string | null;
};

export type AuthedTeam = {
  id: string;
  displayName: string | null;
  billingPlanId: string | null;
};

/**
 * Verify the caller's Stack Auth session. Accepts either a cookie (browser path) or a
 * `Authorization: Bearer <access>` + `X-Stack-Refresh-Token: <refresh>` pair from the
 * native macOS client.
 *
 * Returns the resolved user or null if unauthenticated.
 */
export async function verifyRequest(
  request: Request,
  options: { readonly requestedTeamId?: string | null; readonly allowCookie?: boolean } = {},
): Promise<AuthedUser | null> {
  if (!isStackConfigured()) {
    return null;
  }

  const stackServerApp = getStackServerApp();
  const authHeader = request.headers.get("authorization");
  const refreshHeader = request.headers.get("x-stack-refresh-token");

  if (authHeader?.toLowerCase().startsWith("bearer ") && refreshHeader) {
    const accessToken = authHeader.slice("bearer ".length).trim();
    const refreshToken = refreshHeader.trim();
    if (accessToken && refreshToken) {
      const user = await stackServerApp.getUser({
        tokenStore: { accessToken, refreshToken },
      });
      if (user) {
        return await authedUserFromStackUser(user, options);
      }
    }
  }

  if (options.allowCookie === false) {
    return null;
  }

  // Fall back to the Next.js cookie flow (when browser hits the route).
  const user = await stackServerApp.getUser({ tokenStore: request as unknown as { headers: { get(name: string): string | null } } });
  if (user) {
    return await authedUserFromStackUser(user, options);
  }
  return null;
}

async function authedUserFromStackUser(
  user: StackUserLike,
  options: { readonly requestedTeamId?: string | null },
): Promise<AuthedUser> {
  const selectedTeam = teamLike(user.selectedTeam);
  const requestedTeamId = normalizedOptionalString(options.requestedTeamId);
  // When the selected team is enough, entitlements resolve from it before any
  // multi-team guard needs a full team list.
  const needsListedTeams = !selectedTeam || (!!requestedTeamId && requestedTeamId !== selectedTeam.id);
  const listedTeams = needsListedTeams && typeof user.listTeams === "function"
    ? (await user.listTeams()).map(teamLike).filter((team): team is TeamLike => !!team)
    : [];
  const teamIds = uniqueStrings([
    selectedTeam?.id,
    ...listedTeams.map((team) => team.id),
  ]);
  const teams = uniqueTeams([selectedTeam, ...listedTeams]);
  const billingTeam = selectedTeam ?? (teams.length === 1 ? teams[0] : null);
  const userBillingPlanId = planIdFromMetadata(user.clientReadOnlyMetadata) ?? null;
  const billingPlanId = planIdFromMetadata(billingTeam?.clientReadOnlyMetadata) ?? userBillingPlanId;

  return {
    id: user.id,
    displayName: user.displayName,
    primaryEmail: user.primaryEmail,
    billingCustomerType: billingTeam ? "team" : "user",
    billingTeamId: billingTeam?.id ?? user.id,
    selectedTeamId: selectedTeam?.id ?? null,
    teams: teams.map((team) => ({
      id: team.id,
      displayName: team.displayName,
      billingPlanId: planIdFromMetadata(team.clientReadOnlyMetadata),
    })),
    teamIds,
    userBillingPlanId,
    billingPlanId,
    vmTrialStartedAt: vmTrialStartedAtFromMetadata(user.clientReadOnlyMetadata),
  };
}

type StackUserLike = {
  readonly id: string;
  readonly displayName: string | null;
  readonly primaryEmail: string | null;
  readonly clientReadOnlyMetadata?: unknown;
  readonly selectedTeam?: unknown;
  readonly listTeams?: () => Promise<readonly unknown[]>;
};

type TeamLike = {
  readonly id: string;
  readonly displayName: string | null;
  readonly clientReadOnlyMetadata?: unknown;
};

function teamLike(value: unknown): TeamLike | null {
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

function planIdFromMetadata(metadata: unknown): string | null {
  if (!metadata || typeof metadata !== "object") return null;
  const value = (metadata as { cmuxVmPlan?: unknown; cmuxPlan?: unknown }).cmuxVmPlan ??
    (metadata as { cmuxPlan?: unknown }).cmuxPlan;
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

export const VM_TRIAL_STARTED_AT_METADATA_KEY = "cmuxVmTrialStartedAt";

function vmTrialStartedAtFromMetadata(metadata: unknown): string | null {
  if (!metadata || typeof metadata !== "object") return null;
  const value = (metadata as Record<string, unknown>)[VM_TRIAL_STARTED_AT_METADATA_KEY];
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function uniqueStrings(values: readonly (string | undefined)[]): readonly string[] {
  return [...new Set(values.filter((value): value is string => typeof value === "string" && value.length > 0))];
}

function uniqueTeams(values: readonly (TeamLike | null | undefined)[]): readonly TeamLike[] {
  const teams: TeamLike[] = [];
  const seen = new Set<string>();
  for (const team of values) {
    if (!team || seen.has(team.id)) continue;
    seen.add(team.id);
    teams.push(team);
  }
  return teams;
}

function normalizedOptionalString(value: string | null | undefined): string | null {
  const normalized = value?.trim();
  return normalized ? normalized : null;
}

export function unauthorized(): Response {
  return new Response(JSON.stringify({ error: "unauthorized" }), {
    status: 401,
    headers: { "content-type": "application/json" },
  });
}
