// The complete Pro roster for the admin page.
//
// Two sources, listed separately so an admin can see why an account is Pro:
// - Stripe: active user and team subscription rows, joined to the recorded
//   customer email (no Stack calls).
// - Manual grants: `cmuxVmPlan` overrides on Stack users and teams. Stack has
//   no metadata filter, so these are found by paging through all accounts in
//   bounded pages that the page walks one request at a time.

import { and, desc, eq, inArray, isNotNull, isNull } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { adminPlanGrants, stripeCustomers, stripeSubscriptions } from "../../db/schema";
import { getStackServerApp } from "../../app/lib/stack";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  PRO_PLAN_ID,
  TEAM_PLAN_ID,
  isPaidPlanId,
  manualVmPlanOverride,
} from "../billing/pro";
import {
  grantRecordFromServerMetadata,
  isMissingGrantsTableError,
  type AdminPendingGrantRow,
  type AdminPlanGrantRecord,
  type AdminStackTeam,
  type AdminStackUser,
} from "./proGrants";

export const PRO_LIST_SCAN_PAGE_SIZE = 100;
export const PRO_LIST_MAX_ROWS = 5000;
/** Stack lookups issued at once while resolving team display names. */
export const PRO_LIST_TEAM_LOOKUP_CONCURRENCY = 8;

export type StripeProSubscriber = {
  readonly userId: string;
  readonly email: string | null;
  readonly subscriptionId: string;
  readonly status: string;
  readonly cancelAtPeriodEnd: boolean;
  readonly currentPeriodEnd: string | null;
};

export type StripeTeamSubscription = {
  readonly teamId: string;
  readonly displayName: string | null;
  readonly subscriptionId: string;
  readonly status: string;
  readonly seats: number | null;
  readonly cancelAtPeriodEnd: boolean;
  readonly currentPeriodEnd: string | null;
};

export type ManualUserGrant = {
  readonly userId: string;
  readonly email: string | null;
  readonly emailVerified: boolean;
  readonly plan: string;
  readonly lastGrant: AdminPlanGrantRecord | null;
};

export type ManualTeamGrant = {
  readonly teamId: string;
  readonly displayName: string;
  readonly plan: string;
  readonly lastGrant: AdminPlanGrantRecord | null;
};

/** A list plus whether the hard row cap cut it off. */
export type CappedList<Row> = {
  readonly rows: readonly Row[];
  /** True when more rows exist than PRO_LIST_MAX_ROWS; the UI must say so. */
  readonly truncated: boolean;
};

export type ProListSnapshot = {
  readonly subscribers: readonly StripeProSubscriber[];
  readonly teamSubscriptions: readonly StripeTeamSubscription[];
  readonly pendingGrants: readonly AdminPendingGrantRow[];
  readonly truncated: {
    readonly subscribers: boolean;
    readonly teamSubscriptions: boolean;
    readonly pendingGrants: boolean;
  };
};

export type ProListScanPage<Row> = {
  readonly rows: readonly Row[];
  readonly scanned: number;
  readonly nextCursor: string | null;
};

export type ProListDb = Pick<ReturnType<typeof cloudDb>, "select">;

export type ProListStackApp = {
  getTeam(teamId: string): Promise<Pick<AdminStackTeam, "id" | "displayName"> | null>;
  listUsers(options: {
    cursor?: string;
    limit?: number;
    includeAnonymous?: boolean;
    includeRestricted?: boolean;
  }): Promise<readonly AdminStackUser[] & { readonly nextCursor?: string | null }>;
  listTeams(options: {
    cursor?: string;
    limit?: number;
  }): Promise<readonly AdminStackTeam[] & { readonly nextCursor?: string | null }>;
};

/** Every account with an active Stripe Pro row, newest period first, one row per user. */
export async function listStripeProSubscribers(
  options: { readonly db?: ProListDb } = {},
): Promise<CappedList<StripeProSubscriber>> {
  const db = options.db ?? cloudDb();
  const fetched = await db
    .select({
      userId: stripeSubscriptions.stackUserId,
      subscriptionId: stripeSubscriptions.id,
      status: stripeSubscriptions.status,
      cancelAtPeriodEnd: stripeSubscriptions.cancelAtPeriodEnd,
      currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
      email: stripeCustomers.email,
    })
    .from(stripeSubscriptions)
    .leftJoin(stripeCustomers, eq(stripeSubscriptions.customerId, stripeCustomers.id))
    .where(
      and(
        isNull(stripeSubscriptions.stackTeamId),
        eq(stripeSubscriptions.scope, "user"),
        eq(stripeSubscriptions.plan, PRO_PLAN_ID),
        inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
      ),
    )
    .orderBy(desc(stripeSubscriptions.currentPeriodEnd), desc(stripeSubscriptions.updatedAt))
    .limit(PRO_LIST_MAX_ROWS + 1);
  const truncated = fetched.length > PRO_LIST_MAX_ROWS;
  const rows = fetched.slice(0, PRO_LIST_MAX_ROWS);
  const seen = new Set<string>();
  const out: StripeProSubscriber[] = [];
  for (const row of rows) {
    if (seen.has(row.userId)) continue;
    seen.add(row.userId);
    out.push({
      userId: row.userId,
      email: row.email ?? null,
      subscriptionId: row.subscriptionId,
      status: row.status,
      cancelAtPeriodEnd: Boolean(row.cancelAtPeriodEnd),
      currentPeriodEnd: row.currentPeriodEnd ? row.currentPeriodEnd.toISOString() : null,
    });
  }
  return { rows: out, truncated };
}

/**
 * Every team with an active Stripe Team row, with its Stack display name
 * when reachable. Name lookups run a few at a time so a large roster cannot
 * open thousands of Stack requests at once.
 */
export async function listStripeTeamSubscriptions(
  options: {
    readonly db?: ProListDb;
    readonly app?: ProListStackApp;
    readonly concurrency?: number;
  } = {},
): Promise<CappedList<StripeTeamSubscription>> {
  const db = options.db ?? cloudDb();
  const app = options.app ?? defaultProListStackApp();
  const fetched = await db
    .select({
      teamId: stripeSubscriptions.stackTeamId,
      subscriptionId: stripeSubscriptions.id,
      status: stripeSubscriptions.status,
      seats: stripeSubscriptions.seats,
      cancelAtPeriodEnd: stripeSubscriptions.cancelAtPeriodEnd,
      currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
    })
    .from(stripeSubscriptions)
    .where(
      and(
        isNotNull(stripeSubscriptions.stackTeamId),
        eq(stripeSubscriptions.scope, "team"),
        eq(stripeSubscriptions.plan, TEAM_PLAN_ID),
        inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
      ),
    )
    .orderBy(desc(stripeSubscriptions.currentPeriodEnd), desc(stripeSubscriptions.updatedAt))
    .limit(PRO_LIST_MAX_ROWS + 1);
  const truncated = fetched.length > PRO_LIST_MAX_ROWS;
  const rows = fetched.slice(0, PRO_LIST_MAX_ROWS);
  const seen = new Set<string>();
  const unique = rows.filter((row) => {
    if (!row.teamId || seen.has(row.teamId)) return false;
    seen.add(row.teamId);
    return true;
  });
  const resolved = await mapWithConcurrency(
    unique,
    options.concurrency ?? PRO_LIST_TEAM_LOOKUP_CONCURRENCY,
    async (row): Promise<StripeTeamSubscription> => {
      const team = await app.getTeam(row.teamId!).catch(() => null);
      return {
        teamId: row.teamId!,
        displayName: team?.displayName ?? null,
        subscriptionId: row.subscriptionId,
        status: row.status,
        seats: row.seats ?? null,
        cancelAtPeriodEnd: Boolean(row.cancelAtPeriodEnd),
        currentPeriodEnd: row.currentPeriodEnd ? row.currentPeriodEnd.toISOString() : null,
      };
    },
  );
  return { rows: resolved, truncated };
}

/** Runs `work` over `items` with at most `limit` in flight, preserving order. */
export async function mapWithConcurrency<Item, Result>(
  items: readonly Item[],
  limit: number,
  work: (item: Item) => Promise<Result>,
): Promise<Result[]> {
  const results: Result[] = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await work(items[index]!);
    }
  });
  await Promise.all(workers);
  return results;
}

/** Every open pending email grant, newest first. */
export async function listAllPendingEmailGrants(
  options: { readonly db?: ProListDb } = {},
): Promise<CappedList<AdminPendingGrantRow>> {
  const db = options.db ?? cloudDb();
  const fetched = await db
    .select({
      id: adminPlanGrants.id,
      email: adminPlanGrants.email,
      plan: adminPlanGrants.plan,
      grantedByEmail: adminPlanGrants.grantedByEmail,
      createdAt: adminPlanGrants.createdAt,
    })
    .from(adminPlanGrants)
    .where(and(isNull(adminPlanGrants.appliedAt), isNull(adminPlanGrants.revokedAt)))
    .orderBy(desc(adminPlanGrants.createdAt))
    .limit(PRO_LIST_MAX_ROWS + 1);
  return {
    truncated: fetched.length > PRO_LIST_MAX_ROWS,
    rows: fetched.slice(0, PRO_LIST_MAX_ROWS).map((row) => ({
      id: row.id,
      email: row.email,
      plan: row.plan,
      grantedByEmail: row.grantedByEmail ?? null,
      createdAt: row.createdAt.toISOString(),
    })),
  };
}

/** One page of the Stack user directory, keeping only accounts with a paid manual override. */
export async function scanManualUserGrants(
  cursor: string | null,
  options: { readonly app?: ProListStackApp; readonly pageSize?: number } = {},
): Promise<ProListScanPage<ManualUserGrant>> {
  const app = options.app ?? defaultProListStackApp();
  const users = await app.listUsers({
    cursor: cursor ?? undefined,
    limit: options.pageSize ?? PRO_LIST_SCAN_PAGE_SIZE,
    includeAnonymous: false,
    includeRestricted: true,
  });
  const rows: ManualUserGrant[] = [];
  for (const user of users) {
    if (user.isAnonymous) continue;
    const plan = manualVmPlanOverride(user.clientReadOnlyMetadata);
    if (!isPaidPlanId(plan)) continue;
    rows.push({
      userId: user.id,
      email: user.primaryEmail ?? null,
      emailVerified: user.primaryEmailVerified === true,
      plan: plan!,
      lastGrant: grantRecordFromServerMetadata(user.serverMetadata),
    });
  }
  return { rows, scanned: users.length, nextCursor: users.nextCursor ?? null };
}

/** One page of the Stack team directory, keeping only teams with a paid manual override. */
export async function scanManualTeamGrants(
  cursor: string | null,
  options: { readonly app?: ProListStackApp; readonly pageSize?: number } = {},
): Promise<ProListScanPage<ManualTeamGrant>> {
  const app = options.app ?? defaultProListStackApp();
  const teams = await app.listTeams({
    cursor: cursor ?? undefined,
    limit: options.pageSize ?? PRO_LIST_SCAN_PAGE_SIZE,
  });
  const rows: ManualTeamGrant[] = [];
  for (const team of teams) {
    const plan = manualVmPlanOverride(team.clientReadOnlyMetadata);
    if (!isPaidPlanId(plan)) continue;
    rows.push({
      teamId: team.id,
      displayName: team.displayName,
      plan: plan!,
      lastGrant: grantRecordFromServerMetadata(team.serverMetadata),
    });
  }
  return { rows, scanned: teams.length, nextCursor: teams.nextCursor ?? null };
}

/** Opaque Stack cursors are short tokens; refuse anything that looks like injection or garbage. */
export function isValidScanCursor(value: string): boolean {
  return value.length > 0 && value.length <= 512 && /^[A-Za-z0-9_.:=+/-]+$/.test(value);
}

function defaultProListStackApp(): ProListStackApp {
  const app = getStackServerApp();
  return {
    getTeam: (teamId) => app.getTeam(teamId),
    listUsers: (options) => app.listUsers(options),
    listTeams: (options) => app.listTeams(options),
  };
}

export class ProListDatabaseUnavailableError extends Error {
  constructor() {
    super("Pro roster database is not configured");
    this.name = "ProListDatabaseUnavailableError";
  }
}

/**
 * The Stripe-backed part of the roster in one call, used by the page render
 * and by the API for reloads. A missing admin_plan_grants table (migration
 * not run yet) yields an empty pending list; a missing database throws
 * ProListDatabaseUnavailableError.
 */
export async function loadProListSnapshot(
  options: { readonly db?: ProListDb; readonly app?: ProListStackApp } = {},
): Promise<ProListSnapshot> {
  try {
    const [subscribers, teamSubscriptions, pendingGrants] = await Promise.all([
      listStripeProSubscribers(options),
      listStripeTeamSubscriptions(options),
      listAllPendingEmailGrants(options).catch((error: unknown) => {
        if (isMissingGrantsTableError(error)) return { rows: [], truncated: false };
        throw error;
      }),
    ]);
    return {
      subscribers: subscribers.rows,
      teamSubscriptions: teamSubscriptions.rows,
      pendingGrants: pendingGrants.rows,
      truncated: {
        subscribers: subscribers.truncated,
        teamSubscriptions: teamSubscriptions.truncated,
        pendingGrants: pendingGrants.truncated,
      },
    };
  } catch (error) {
    if (error instanceof Error && /DATABASE_URL is required/.test(error.message)) {
      throw new ProListDatabaseUnavailableError();
    }
    throw error;
  }
}
