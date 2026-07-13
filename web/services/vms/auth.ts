import { eq } from "drizzle-orm";
import { getStackServerApp, isStackConfigured } from "../../app/lib/stack";
import { cloudDb } from "../../db/client";
import { accountDeletionTombstones } from "../../db/schema";
import {
  accountDeletionUserHash,
  isBlockingAccountDeletionTombstone,
} from "../account/deletionLock";
import {
  billingPlanIdFromMetadata,
  billingTeamFromUnknown,
  resolveBillingTeam,
  type BillingTeamLike,
} from "../billing/teamResolution";

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
  options: {
    readonly requestedTeamId?: string | null;
    readonly allowCookie?: boolean;
    readonly allowDeletingAccount?: boolean;
  } = {},
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
  options: { readonly requestedTeamId?: string | null; readonly allowDeletingAccount?: boolean },
): Promise<AuthedUser | null> {
  if (!options.allowDeletingAccount && await isAccountDeletionAuthBlocked(user)) {
    return null;
  }

  const selectedTeam = billingTeamFromUnknown(user.selectedTeam);
  const requestedTeamId = normalizedOptionalString(options.requestedTeamId);
  // When the selected team is enough, entitlements resolve from it before any
  // multi-team guard needs a full team list.
  const needsListedTeams = !selectedTeam || (!!requestedTeamId && requestedTeamId !== selectedTeam.id);
  const listedTeams = needsListedTeams && typeof user.listTeams === "function"
    ? (await user.listTeams()).map(billingTeamFromUnknown).filter((team): team is BillingTeamLike => !!team)
    : [];
  const teamIds = uniqueStrings([
    selectedTeam?.id,
    ...listedTeams.map((team) => team.id),
  ]);
  const teams = uniqueTeams([selectedTeam, ...listedTeams]);
  const billingTeam = await resolveBillingTeam({
    selectedTeam,
    listTeams: async () => listedTeams,
  });
  const userBillingPlanId = billingPlanIdFromMetadata(user.clientReadOnlyMetadata) ?? null;
  const billingPlanId = billingPlanIdFromMetadata(billingTeam?.clientReadOnlyMetadata) ?? userBillingPlanId;

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
      billingPlanId: billingPlanIdFromMetadata(team.clientReadOnlyMetadata),
    })),
    teamIds,
    userBillingPlanId,
    billingPlanId,
  };
}

async function isAccountDeletionAuthBlocked(user: StackUserLike): Promise<boolean> {
  if (!hasAccountDeletionMetadataFlag(user.clientReadOnlyMetadata)) return false;
  const userIdHash = accountDeletionUserHash(user.id);
  const [deletion] = await cloudDb()
    .select({
      userIdHash: accountDeletionTombstones.userIdHash,
      status: accountDeletionTombstones.status,
      updatedAt: accountDeletionTombstones.updatedAt,
    })
    .from(accountDeletionTombstones)
    .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
    .limit(1);
  return deletion?.userIdHash === userIdHash &&
    isBlockingAccountDeletionTombstone(deletion);
}

function hasAccountDeletionMetadataFlag(metadata: unknown): boolean {
  return !!metadata &&
    typeof metadata === "object" &&
    !Array.isArray(metadata) &&
    (metadata as { cmuxAccountDeleting?: unknown }).cmuxAccountDeleting === true;
}

type StackUserLike = {
  readonly id: string;
  readonly displayName: string | null;
  readonly primaryEmail: string | null;
  readonly clientReadOnlyMetadata?: unknown;
  readonly selectedTeam?: unknown;
  readonly listTeams?: () => Promise<readonly unknown[]>;
};

function uniqueStrings(values: readonly (string | undefined)[]): readonly string[] {
  return [...new Set(values.filter((value): value is string => typeof value === "string" && value.length > 0))];
}

function uniqueTeams(values: readonly (BillingTeamLike | null | undefined)[]): readonly BillingTeamLike[] {
  const teams: BillingTeamLike[] = [];
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
