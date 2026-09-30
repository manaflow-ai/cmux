import { and, desc, eq, inArray } from "drizzle-orm";

import { getStackServerApp } from "../../app/lib/stack";
import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import { ACTIVE_STRIPE_PRO_STATUSES, TEAM_PLAN_ID } from "./pro";

/**
 * Stack Auth owns the Team settings page, including invitations and member
 * changes. There is no local mutation route to guard, so this module applies
 * the seat license when a Team entitlement is consumed.
 */

const DEFAULT_TEAM_SEAT_CACHE_TTL_MS = 30_000;
const MAX_TEAM_SEAT_CACHE_ENTRIES = 256;
const MAX_TEAM_MEMBER_PAGES = 100;
const TEAM_MEMBER_PAGE_SIZE = 100;
const MAX_TEAM_MEMBERS = 10_000;
const TEAM_MEMBER_READ_TIMEOUT_MS = 15_000;

type TeamMemberListOptions = {
  readonly cursor?: string;
  readonly limit?: number;
};

type StackTeamMemberList = readonly unknown[] & {
  readonly nextCursor?: string | null;
};

type StackSeatTeam = {
  readonly listUsers?: (
    options?: TeamMemberListOptions,
  ) => Promise<unknown> | unknown;
};

type StackSeatApp = {
  readonly getTeam?: (id: string) => Promise<unknown> | unknown;
};

/** A small structural seam. It also keeps tests independent of Stack classes. */
export type TeamSeatResolverOptions = {
  readonly stackApp?: StackSeatApp | null;
  /** A Team object returned by Stack Auth. `team` is retained as an alias. */
  readonly stackTeam?: unknown;
  readonly team?: unknown;
  /** Optional state snapshot supplied by a caller that already read billing. */
  readonly subscription?: TeamSubscriptionSeatSnapshot;
  /** Test and service seam for loading the durable subscription quantity. */
  readonly loadSubscription?: (
    stackTeamId: string,
  ) => Promise<TeamSubscriptionSeatSnapshot>;
  /** Set false when a caller explicitly needs an uncached read. */
  readonly cache?: boolean;
};

export type TeamSubscriptionSeatSnapshot = {
  /** True when an active Team subscription row exists. */
  readonly active: boolean;
  /** The licensed quantity from that row, if it is present and valid. */
  readonly seats: number | null;
  /** True when the billing read was unavailable, rather than inactive. */
  readonly unavailable?: boolean;
};

/** The result used by both billing-plan and VM entitlement resolution. */
export type TeamSeatDecision = {
  readonly status: "active" | "inactive" | "unavailable";
  readonly entitled: boolean;
  readonly seatCount: number | null;
  readonly memberCount: number | null;
  readonly memberListingAvailable: boolean;
};

type TeamMember = {
  readonly id: string;
  readonly createdAtMs: number | null;
};

type TeamMemberRoster = {
  readonly available: boolean;
  readonly members: readonly TeamMember[];
};

type CachedValue<T> = {
  readonly expiresAt: number;
  readonly value: Promise<T>;
};

const subscriptionCache = new Map<string, CachedValue<TeamSubscriptionSeatSnapshot>>();
const rosterCache = new Map<string, CachedValue<TeamMemberRoster>>();

/**
 * Read the active Team subscription and its quantity from the durable billing
 * row. Stack metadata is not used for the seat count.
 */
export async function teamSubscriptionSeatSnapshot(
  stackTeamId: string,
): Promise<TeamSubscriptionSeatSnapshot> {
  try {
    const db = cloudDb();
    const query = db
      .select({
        id: stripeSubscriptions.id,
        seats: stripeSubscriptions.seats,
        updatedAt: stripeSubscriptions.updatedAt,
        currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
      })
      .from(stripeSubscriptions)
      .where(
        and(
          eq(stripeSubscriptions.stackTeamId, stackTeamId),
          eq(stripeSubscriptions.scope, "team"),
          eq(stripeSubscriptions.plan, TEAM_PLAN_ID),
          inArray(stripeSubscriptions.status, [...ACTIVE_STRIPE_PRO_STATUSES]),
        ),
      );
    // Lightweight test doubles can omit orderBy. The production query uses it
    // so a renewed row is preferred when more than one active row exists.
    const orderedQuery = typeof query.orderBy === "function"
      ? query.orderBy(
          desc(stripeSubscriptions.updatedAt),
          desc(stripeSubscriptions.currentPeriodEnd),
        )
      : query;
    const limited = typeof orderedQuery.limit === "function"
      ? orderedQuery.limit(10)
      : orderedQuery;
    const rows = await limited as readonly { seats?: unknown }[];
    const row = rows[0];
    return {
      active: row !== undefined,
      seats: row ? normalizedSeatCount(row.seats) : null,
      unavailable: false,
    };
  } catch {
    // Entitlement checks must not turn a temporary billing database outage into
    // a mass sign-out. The existing Team metadata remains authoritative until
    // the next bounded read succeeds.
    return { active: false, seats: null, unavailable: true };
  }
}

/**
 * Decide whether one Stack user is covered by a Team subscription's seats.
 * When membership creation dates are absent (the current Stack response), the
 * resolver keeps the lexicographically oldest member ids. This is deterministic
 * across requests and is documented instead of depending on API result order.
 */
export async function resolveTeamSeatEntitlement(
  stackTeamId: string,
  stackUserId: string,
  options: TeamSeatResolverOptions = {},
): Promise<TeamSeatDecision> {
  const subscription = await loadSubscriptionSnapshot(stackTeamId, options);

  if (!subscription.active) {
    return {
      status: subscription.unavailable ? "unavailable" : "inactive",
      entitled: Boolean(subscription.unavailable),
      seatCount: null,
      memberCount: null,
      memberListingAvailable: false,
    };
  }

  const seatCount = normalizedSeatCount(subscription.seats);
  // Rows written before the seats column was introduced have no quantity. Do
  // not revoke those existing subscriptions until billing reconciliation fills
  // the value; current Team checkout rows always store a positive quantity.
  if (seatCount === null) {
    return {
      status: "active",
      entitled: true,
      seatCount: null,
      memberCount: null,
      memberListingAvailable: false,
    };
  }

  const roster = await loadCachedRoster(stackTeamId, options);
  if (!roster.available) {
    // A known paid quantity with no readable roster fails closed. Otherwise a
    // hosted Stack outage could grant every member an unbounded Team seat.
    return {
      status: "active",
      entitled: false,
      seatCount,
      memberCount: null,
      memberListingAvailable: false,
    };
  }

  const memberIds = new Set(roster.members.map((member) => member.id));
  if (!memberIds.has(stackUserId)) {
    return {
      status: "active",
      entitled: false,
      seatCount,
      memberCount: roster.members.length,
      memberListingAvailable: true,
    };
  }

  if (roster.members.length <= seatCount) {
    return {
      status: "active",
      entitled: true,
      seatCount,
      memberCount: roster.members.length,
      memberListingAvailable: true,
    };
  }

  const assigned = assignedSeatMemberIds(roster.members, seatCount);
  return {
    status: "active",
    entitled: assigned.has(stackUserId),
    seatCount,
    memberCount: roster.members.length,
    memberListingAvailable: true,
  };
}

/**
 * Return true when a caller has a possible Stack roster reader. A numeric
 * subscription quantity also makes the gate applicable, so an unavailable
 * reader is handled by the fail-closed decision above.
 */
export function teamSeatMemberListingAvailable(
  options: TeamSeatResolverOptions,
): boolean {
  const team = options.stackTeam ?? options.team;
  if (hasListUsers(team)) return true;
  if (hasGetTeam(options.stackApp)) return true;
  return options.subscription?.active === true &&
    normalizedSeatCount(options.subscription.seats) !== null;
}

/** Apply the seat gate only to the Team plan. */
export async function effectiveTeamPlanForMember(
  planId: string | null,
  stackTeamId: string,
  stackUserId: string,
  options: TeamSeatResolverOptions = {},
): Promise<string | null> {
  if (planId?.trim().toLowerCase() !== TEAM_PLAN_ID) return planId;
  const decision = await resolveTeamSeatEntitlement(
    stackTeamId,
    stackUserId,
    options,
  );
  return decision.entitled ? planId : "free";
}

/** Test hook for clearing process-local subscription and roster state. */
export function clearTeamSeatCacheForTests(): void {
  subscriptionCache.clear();
  rosterCache.clear();
}

async function loadSubscriptionSnapshot(
  stackTeamId: string,
  options: TeamSeatResolverOptions,
): Promise<TeamSubscriptionSeatSnapshot> {
  if (options.subscription) return normalizeSubscription(options.subscription);

  const loader = options.loadSubscription ?? teamSubscriptionSeatSnapshot;
  const useCache = options.cache !== false;
  if (!useCache) return safeSubscriptionRead(loader, stackTeamId);

  const now = Date.now();
  const cached = subscriptionCache.get(stackTeamId);
  if (cached && cached.expiresAt > now) return cached.value;
  if (cached) subscriptionCache.delete(stackTeamId);

  const value = safeSubscriptionRead(loader, stackTeamId);
  setBoundedCache(subscriptionCache, stackTeamId, value, now);
  return value;
}

async function safeSubscriptionRead(
  loader: (stackTeamId: string) => Promise<TeamSubscriptionSeatSnapshot>,
  stackTeamId: string,
): Promise<TeamSubscriptionSeatSnapshot> {
  try {
    return normalizeSubscription(await loader(stackTeamId));
  } catch {
    return { active: false, seats: null, unavailable: true };
  }
}

function normalizeSubscription(
  value: TeamSubscriptionSeatSnapshot | null | undefined,
): TeamSubscriptionSeatSnapshot {
  if (!value || typeof value !== "object") {
    return { active: false, seats: null, unavailable: true };
  }
  return {
    active: value.active === true,
    seats: normalizedSeatCount(value.seats),
    unavailable: value.unavailable === true,
  };
}

async function loadCachedRoster(
  stackTeamId: string,
  options: TeamSeatResolverOptions,
): Promise<TeamMemberRoster> {
  const useCache = options.cache !== false;
  if (!useCache) return loadTeamRoster(stackTeamId, options);

  const now = Date.now();
  const cached = rosterCache.get(stackTeamId);
  if (cached && cached.expiresAt > now) return cached.value;
  if (cached) rosterCache.delete(stackTeamId);

  const value = loadTeamRoster(stackTeamId, options);
  setBoundedCache(rosterCache, stackTeamId, value, now);
  return value;
}

function setBoundedCache<T>(
  cache: Map<string, CachedValue<T>>,
  key: string,
  value: Promise<T>,
  now: number,
): void {
  if (cache.size >= MAX_TEAM_SEAT_CACHE_ENTRIES) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  const entry: CachedValue<T> = {
    expiresAt: now + teamSeatCacheTtlMs(),
    value,
  };
  cache.set(key, entry);
  // A rejected Stack request must not poison the cache until its TTL expires.
  void value.catch(() => {
    if (cache.get(key) === entry) cache.delete(key);
  });
}

async function loadTeamRoster(
  stackTeamId: string,
  options: TeamSeatResolverOptions,
): Promise<TeamMemberRoster> {
  let team = stackTeamFromUnknown(options.stackTeam ?? options.team);
  if (!team) {
    try {
      const app = options.stackApp ?? (getStackServerApp() as unknown as StackSeatApp);
      if (!hasGetTeam(app)) return { available: false, members: [] };
      team = stackTeamFromUnknown(await app.getTeam!(stackTeamId));
    } catch {
      return { available: false, members: [] };
    }
  }
  if (!team || !hasListUsers(team)) {
    return { available: false, members: [] };
  }

  try {
    const rawMembers = await listAllTeamMembers(team);
    return { available: true, members: normalizeMembers(rawMembers) };
  } catch {
    return { available: false, members: [] };
  }
}

async function listAllTeamMembers(team: StackSeatTeam): Promise<readonly unknown[]> {
  const members: unknown[] = [];
  const seenCursors = new Set<string>();
  let cursor: string | undefined;

  for (let pageIndex = 0; pageIndex < MAX_TEAM_MEMBER_PAGES; pageIndex += 1) {
    const response = await withDeadline(
      () => cursor
        ? team.listUsers!({ cursor, limit: TEAM_MEMBER_PAGE_SIZE })
        : team.listUsers!({ limit: TEAM_MEMBER_PAGE_SIZE }),
      TEAM_MEMBER_READ_TIMEOUT_MS,
    );
    const page = teamMemberPage(response);
    if (!page) throw new Error("Stack team member listing returned an invalid result");
    members.push(...page.members);
    if (members.length > MAX_TEAM_MEMBERS) {
      throw new Error("Stack team member listing exceeded its bound");
    }
    const nextCursor = normalizedCursor(page.nextCursor);
    if (!nextCursor) return members;
    if (seenCursors.has(nextCursor)) {
      throw new Error("Stack team member pagination repeated a cursor");
    }
    seenCursors.add(nextCursor);
    cursor = nextCursor;
  }
  throw new Error("Stack team member pagination exceeded its page bound");
}

function stackTeamFromUnknown(value: unknown): StackSeatTeam | null {
  if (!value || typeof value !== "object") return null;
  const listUsers = (value as { readonly listUsers?: unknown }).listUsers;
  if (typeof listUsers !== "function") return null;
  return {
    listUsers: (options) =>
      (listUsers as (options?: TeamMemberListOptions) => Promise<unknown> | unknown)
        .call(value, options),
  };
}

function hasListUsers(value: unknown): value is StackSeatTeam {
  return !!stackTeamFromUnknown(value);
}

function hasGetTeam(value: unknown): value is StackSeatApp & {
  readonly getTeam: (id: string) => Promise<unknown> | unknown;
} {
  return !!value && typeof value === "object" &&
    typeof (value as { readonly getTeam?: unknown }).getTeam === "function";
}

function teamMemberPage(
  value: unknown,
): { readonly members: readonly unknown[]; readonly nextCursor: unknown } | null {
  if (Array.isArray(value)) {
    return {
      members: value,
      nextCursor: (value as StackTeamMemberList).nextCursor,
    };
  }
  if (!value || typeof value !== "object") return null;
  const record = value as Record<string, unknown>;
  const members = [record.members, record.users, record.items, record.data]
    .find((candidate): candidate is readonly unknown[] => Array.isArray(candidate));
  return members
    ? { members, nextCursor: record.nextCursor ?? record.next_cursor }
    : null;
}

function normalizeMembers(values: readonly unknown[]): readonly TeamMember[] {
  const byId = new Map<string, TeamMember>();
  for (const value of values) {
    if (!value || typeof value !== "object") continue;
    const rawId = (value as { readonly id?: unknown }).id;
    if (typeof rawId !== "string" || !rawId.trim()) continue;
    const id = rawId.trim();
    const member = {
      id,
      createdAtMs: membershipCreatedAtMs(value),
    };
    const existing = byId.get(id);
    if (!existing || (existing.createdAtMs === null && member.createdAtMs !== null)) {
      byId.set(id, member);
    }
  }
  return [...byId.values()];
}

/**
 * Use an explicit membership/join timestamp only when Stack exposes one. Do
 * not use a user's sign-up date: that is not the date they joined this team.
 */
function membershipCreatedAtMs(value: object): number | null {
  const record = value as Record<string, unknown>;
  const membership = record.membership;
  const candidates = [
    record.membershipCreatedAt,
    record.membership_created_at,
    record.joinedAt,
    record.joined_at,
    record.createdAt,
    record.created_at,
    membership && typeof membership === "object"
      ? (membership as Record<string, unknown>).createdAt
      : undefined,
    membership && typeof membership === "object"
      ? (membership as Record<string, unknown>).created_at
      : undefined,
  ];
  for (const candidate of candidates) {
    const parsed = timestampMs(candidate);
    if (parsed !== null) return parsed;
  }
  return null;
}

function timestampMs(value: unknown): number | null {
  if (value instanceof Date) {
    const timestamp = value.getTime();
    return Number.isFinite(timestamp) ? timestamp : null;
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.abs(value) < 1_000_000_000_000 ? value * 1_000 : value;
  }
  if (typeof value !== "string" || !value.trim()) return null;
  const numeric = Number(value);
  if (Number.isFinite(numeric)) {
    return Math.abs(numeric) < 1_000_000_000_000 ? numeric * 1_000 : numeric;
  }
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function assignedSeatMemberIds(
  members: readonly TeamMember[],
  seats: number,
): ReadonlySet<string> {
  const hasCompleteDates = members.every((member) => member.createdAtMs !== null);
  const ordered = [...members].sort((left, right) => {
    if (hasCompleteDates) {
      const dateOrder = left.createdAtMs! - right.createdAtMs!;
      if (dateOrder !== 0) return dateOrder;
    }
    return compareMemberIds(left.id, right.id);
  });
  return new Set(ordered.slice(0, seats).map((member) => member.id));
}

function compareMemberIds(left: string, right: string): number {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function normalizedCursor(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function normalizedSeatCount(value: unknown): number | null {
  if (typeof value === "number") {
    return Number.isSafeInteger(value) && value >= 1 ? value : null;
  }
  if (typeof value === "string" && /^\d+$/.test(value.trim())) {
    const parsed = Number(value.trim());
    return Number.isSafeInteger(parsed) && parsed >= 1 ? parsed : null;
  }
  return null;
}

function teamSeatCacheTtlMs(raw = process.env.CMUX_TEAM_SEAT_CACHE_TTL_MS): number {
  if (raw === undefined || raw.trim() === "") return DEFAULT_TEAM_SEAT_CACHE_TTL_MS;
  const parsed = Number(raw.trim());
  return Number.isSafeInteger(parsed) && parsed >= 0
    ? parsed
    : DEFAULT_TEAM_SEAT_CACHE_TTL_MS;
}

async function withDeadline<T>(
  operation: () => Promise<T> | T,
  timeoutMs: number,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(
      () => reject(new Error("Stack team member listing exceeded its deadline")),
      timeoutMs,
    );
  });
  try {
    return await Promise.race([
      Promise.resolve().then(operation),
      timeout,
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
