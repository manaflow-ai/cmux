import { mock } from "bun:test";

import { stripeCustomers, stripeSubscriptions } from "../../db/schema";

export type FixtureTeam = {
  readonly id: string;
  readonly displayName: string;
  readonly clientReadOnlyMetadata: Record<string, unknown>;
  listUsers(): Promise<unknown[]>;
  delete(): Promise<void>;
};

export function fixtureTeam(
  id: string,
  options: { displayName?: string; members?: number; metadata?: Record<string, unknown> } = {},
): FixtureTeam {
  const members = options.members ?? 2;
  return {
    id,
    displayName: options.displayName ?? id,
    clientReadOnlyMetadata: options.metadata ?? {},
    listUsers: async () => Array.from({ length: members }, (_, index) => ({ id: `${id}-member-${index}` })),
    delete: mock(async () => undefined),
  };
}

/**
 * A Stack server user whose team membership and `team_admin` permission are
 * explicit: `teams` are the member teams, `adminTeamIds` the ones where
 * hasPermission(team, "team_admin") is true.
 */
export function fixtureStackUser(input: {
  id: string;
  teams?: FixtureTeam[];
  adminTeamIds?: string[];
  selectedTeam?: FixtureTeam | null;
  primaryEmail?: string | null;
  metadata?: Record<string, unknown>;
}) {
  const teams = input.teams ?? [];
  const admins = new Set(input.adminTeamIds ?? []);
  return {
    id: input.id,
    isAnonymous: false,
    isRestricted: false,
    primaryEmail: input.primaryEmail ?? `${input.id}@example.com`,
    primaryEmailVerified: false,
    displayName: input.id,
    clientReadOnlyMetadata: input.metadata ?? {},
    selectedTeam: input.selectedTeam ?? null,
    getTeam: mock(async (teamId: string) => teams.find((team) => team.id === teamId) ?? null),
    listTeams: mock(async () => teams),
    hasPermission: mock(async (team: { id: string }, permission: string) =>
      permission === "team_admin" && admins.has(team.id)),
    grantPermission: mock(async (_team: unknown, _permission: string) => undefined),
    createTeam: mock(async (_data: { displayName: string }) => fixtureTeam("created-team", { displayName: "cmux Team" })),
    update: mock(async () => undefined),
  };
}

export type BillingDbRows = {
  customers: Array<Record<string, unknown>>;
  subscriptions: Array<Record<string, unknown>>;
  inserted: Array<Record<string, unknown>>;
};

export function emptyBillingDbRows(): BillingDbRows {
  return { customers: [], subscriptions: [], inserted: [] };
}

/**
 * A drizzle-shaped stub: any select chain resolves to the rows for its table,
 * whether awaited directly or through `.limit()` / `.orderBy().limit()`.
 * Inserts are recorded.
 */
export function stubBillingDb(rows: () => BillingDbRows) {
  const rowsFor = (table: unknown) => {
    if (table === stripeCustomers) return rows().customers;
    if (table === stripeSubscriptions) return rows().subscriptions;
    return [];
  };
  const chain = (table: unknown): Record<string, unknown> => {
    const result = {
      then: (resolve: (value: unknown) => unknown, reject?: (error: unknown) => unknown) =>
        Promise.resolve(rowsFor(table)).then(resolve, reject),
      where: () => chain(table),
      orderBy: () => chain(table),
      limit: async () => rowsFor(table),
    };
    return result;
  };
  return {
    select: () => ({ from: (table: unknown) => chain(table) }),
    insert: () => ({
      values: (values: Record<string, unknown>) => {
        rows().inserted.push(values);
        return Promise.resolve();
      },
    }),
    update: () => ({ set: () => ({ where: () => Promise.resolve() }) }),
  };
}

export function activeTeamSubscriptionRow(seats = 3): Record<string, unknown> {
  return {
    id: "sub_team",
    status: "active",
    plan: "team",
    scope: "team",
    seats,
    priceId: "price_team",
    cancelAtPeriodEnd: false,
    currentPeriodEnd: new Date("2026-12-01T00:00:00Z"),
    updatedAt: new Date("2026-09-01T00:00:00Z"),
    raw: { items: { data: [{ price: { unit_amount: 6000, currency: "usd", recurring: { interval: "month" } } }] } },
  };
}
