import { eq } from "drizzle-orm";
import type { Team } from "@stackframe/stack";
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
  resolveSubrouterPermissions: (
    teamId: string,
  ) => Promise<SubrouterPermissions>;
};

export type AuthedTeam = {
  id: string;
  displayName: string | null;
  billingPlanId: string | null;
};

export type SubrouterPermissions = {
  readonly use: boolean;
  readonly manageAccounts: boolean;
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
    readonly listAllTeams?: boolean;
  } = {},
): Promise<AuthedUser | null> {
  if (!isStackConfigured()) {
    return null;
  }

  const stackServerApp = getStackServerApp();
  const authHeader = request.headers.get("authorization");
  const refreshHeader = request.headers.get("x-stack-refresh-token");

  if (authHeader !== null || refreshHeader !== null) {
    if (!authHeader?.toLowerCase().startsWith("bearer ") || !refreshHeader) {
      return null;
    }
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
    // A caller that presents native credentials must succeed or fail as that
    // native session. Falling back to an ambient browser cookie would let an
    // invalid bearer bypass mutation-origin checks.
    return null;
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
  options: {
    readonly requestedTeamId?: string | null;
    readonly allowDeletingAccount?: boolean;
    readonly listAllTeams?: boolean;
  },
): Promise<AuthedUser | null> {
  if (!options.allowDeletingAccount && await isAccountDeletionAuthBlocked(user)) {
    return null;
  }

  const selectedTeamRaw = user.selectedTeam;
  const selectedTeam = billingTeamFromUnknown(selectedTeamRaw);
  const requestedTeamId = normalizedOptionalString(options.requestedTeamId);
  // When the selected team is enough, entitlements resolve from it before any
  // multi-team guard needs a full team list.
  const needsListedTeams =
    options.listAllTeams === true ||
    !selectedTeam ||
    (!!requestedTeamId && requestedTeamId !== selectedTeam.id);
  const listedTeamRaw = needsListedTeams && typeof user.listTeams === "function"
    ? await listAllStackTeams(user)
    : [];
  const listedTeams = listedTeamRaw
    .map(billingTeamFromUnknown)
    .filter((team): team is BillingTeamLike => !!team);
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
  const rawTeams = new Map<string, unknown>();
  if (selectedTeam) rawTeams.set(selectedTeam.id, selectedTeamRaw);
  for (const raw of listedTeamRaw) {
    const team = billingTeamFromUnknown(raw);
    if (team) rawTeams.set(team.id, raw);
  }
  const enforceSubrouterPermissions =
    process.env.SUBROUTER_ENFORCE_STACK_PERMISSIONS === "1";
  const authedTeams = teams.map((team) => ({
    id: team.id,
    displayName: team.displayName,
    billingPlanId: billingPlanIdFromMetadata(team.clientReadOnlyMetadata),
  }));

  return {
    id: user.id,
    displayName: user.displayName,
    primaryEmail: user.primaryEmail,
    billingCustomerType: billingTeam ? "team" : "user",
    billingTeamId: billingTeam?.id ?? user.id,
    selectedTeamId: selectedTeam?.id ?? null,
    teams: authedTeams,
    teamIds,
    userBillingPlanId,
    billingPlanId,
    resolveSubrouterPermissions: async (teamId) => {
      if (teamId === user.id) {
        return subrouterPermissions(
          user,
          undefined,
          enforceSubrouterPermissions,
        );
      }
      const rawTeam = rawTeams.get(teamId);
      if (!rawTeam) return { use: false, manageAccounts: false };
      return subrouterPermissions(
        user,
        rawTeam,
        enforceSubrouterPermissions,
      );
    },
  };
}

async function subrouterPermissions(
  user: StackUserLike,
  team: unknown,
  enforce: boolean,
): Promise<SubrouterPermissions> {
  if (!enforce) return { use: true, manageAccounts: true };
  if (typeof user.hasPermission !== "function") {
    return { use: false, manageAccounts: false };
  }
  try {
    const use = team
      ? await user.hasPermission(team as Team, "subrouter:use")
      : await user.hasPermission("subrouter:use");
    const manageAccounts = team
      ? await user.hasPermission(team as Team, "subrouter:manage_accounts")
      : await user.hasPermission("subrouter:manage_accounts");
    return { use, manageAccounts };
  } catch {
    return { use: false, manageAccounts: false };
  }
}

const MAX_STACK_TEAM_PAGES = 100;
const STACK_TEAM_PAGE_SIZE = 100;

async function listAllStackTeams(user: StackUserLike): Promise<readonly unknown[]> {
  if (typeof user.listTeams !== "function") return [];

  const teams: unknown[] = [];
  const seenCursors = new Set<string>();
  let cursor: string | undefined;
  for (let pageIndex = 0; pageIndex < MAX_STACK_TEAM_PAGES; pageIndex++) {
    const page = await user.listTeams({
      cursor,
      limit: STACK_TEAM_PAGE_SIZE,
    });
    teams.push(...page);
    const nextCursor = normalizedOptionalString(page.nextCursor);
    if (!nextCursor) return teams;
    if (seenCursors.has(nextCursor)) {
      throw new Error("Stack team pagination repeated a cursor");
    }
    seenCursors.add(nextCursor);
    cursor = nextCursor;
  }
  throw new Error("Stack team pagination exceeded its page limit");
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
  readonly listTeams?: (
    options?: { readonly cursor?: string; readonly limit?: number },
  ) => Promise<readonly unknown[] & { readonly nextCursor?: string | null }>;
  readonly hasPermission?: {
    (permissionId: string): Promise<boolean>;
    (scope: Team, permissionId: string): Promise<boolean>;
  };
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
