import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { accountMutationLeases, adminPlanGrants, stripeSubscriptions } from "../db/schema";
import { withAccountMutationLeaseSupport } from "./helpers/account-mutation-db-mock";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

type StackUser = {
  id: string;
  primaryEmail: string | null;
  primaryEmailVerified: boolean;
  displayName: string | null;
  isAnonymous: boolean;
  signedUpAt: Date;
  clientReadOnlyMetadata: Record<string, unknown>;
  serverMetadata: Record<string, unknown>;
  updates: Array<Record<string, unknown>>;
  update(options: Record<string, unknown>): Promise<void>;
};

function stackUser(overrides: Partial<StackUser> & { id: string }): StackUser {
  const user: StackUser = {
    primaryEmail: `${overrides.id}@example.com`,
    primaryEmailVerified: true,
    displayName: null,
    isAnonymous: false,
    signedUpAt: new Date("2026-01-01T00:00:00.000Z"),
    clientReadOnlyMetadata: {},
    serverMetadata: {},
    updates: [],
    async update(options) {
      user.updates.push(options);
      if ("clientReadOnlyMetadata" in options) {
        user.clientReadOnlyMetadata = options.clientReadOnlyMetadata as Record<string, unknown>;
      }
      if ("serverMetadata" in options) {
        user.serverMetadata = options.serverMetadata as Record<string, unknown>;
      }
    },
    ...overrides,
  };
  return user;
}

let stackConfigured = true;
let currentUser: StackUser | null = null;
let directory: StackUser[] = [];

const getUser = mock(async (arg: unknown) => {
  if (typeof arg === "string") return directory.find((user) => user.id === arg) ?? null;
  return currentUser;
});
const listUsers = mock(async (options: unknown) => {
  const query = ((options as { query?: string }).query ?? "").toLowerCase();
  return directory.filter((user) => (user.primaryEmail ?? "").toLowerCase().includes(query));
});

type StackTeam = {
  id: string;
  displayName: string;
  createdAt: Date;
  clientReadOnlyMetadata: Record<string, unknown>;
  serverMetadata: Record<string, unknown>;
  updates: Array<Record<string, unknown>>;
  listUsers(): Promise<Array<{ id: string }>>;
  update(options: Record<string, unknown>): Promise<void>;
};

function stackTeam(overrides: Partial<StackTeam> & { id: string }): StackTeam {
  const team: StackTeam = {
    displayName: `Team ${overrides.id}`,
    createdAt: new Date("2026-02-01T00:00:00.000Z"),
    clientReadOnlyMetadata: {},
    serverMetadata: {},
    updates: [],
    async listUsers() {
      return [{ id: "m1" }, { id: "m2" }];
    },
    async update(options) {
      team.updates.push(options);
      if ("clientReadOnlyMetadata" in options) {
        team.clientReadOnlyMetadata = options.clientReadOnlyMetadata as Record<string, unknown>;
      }
      if ("serverMetadata" in options) {
        team.serverMetadata = options.serverMetadata as Record<string, unknown>;
      }
    },
    ...overrides,
  };
  return team;
}

let teamDirectory: StackTeam[] = [];
const getTeam = mock(async (teamId: unknown) => teamDirectory.find((team) => team.id === teamId) ?? null);
const listTeams = mock(async (options: unknown) => {
  const query = ((options as { query?: string }).query ?? "").toLowerCase();
  return teamDirectory.filter((team) => team.displayName.toLowerCase().includes(query));
});

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser, listUsers, getTeam, listTeams }),
  isStackConfigured: () => stackConfigured,
  promoteStackUserFromAnonymousViaApi: async () => undefined,
  stackServerApp: { getUser, listUsers, getTeam, listTeams },
}));

// Recorded pending grants (admin_plan_grants) and recorded subscription
// snapshots, kept as plain arrays so route tests can assert on them.
let pendingGrantRows: Array<Record<string, unknown>> = [];
let grantsTableMissing = false;
let subscriptionRows: Array<{ id: string }> = [];
let subscriptionListRows: Array<Record<string, unknown>> = [];
let subscriptionUpdates: Array<Record<string, unknown>> = [];
const stripeSubscriptionUpdate = mock(async (id: unknown, params: unknown) => ({
  id,
  cancel_at_period_end: (params as { cancel_at_period_end?: boolean }).cancel_at_period_end,
}));

mock.module("../services/billing/stripe", () => ({
  isStripeBillingConfigured: () => true,
  stripe: () => ({ subscriptions: { update: stripeSubscriptionUpdate } }),
}));

function adminDbMock() {
  const base = {
      select: () => ({
        from: (table: unknown) => ({
          leftJoin: () => ({
            where: () => ({
              orderBy: () => ({
                limit: async () => (table === stripeSubscriptions ? subscriptionListRows : []),
              }),
            }),
          }),
          where: () => ({
            limit: async () => (table === stripeSubscriptions ? [] : []),
            orderBy: () => ({
              limit: async () =>
                table === adminPlanGrants
                  ? pendingGrantRows.filter((row) => !row.appliedAt && !row.revokedAt)
                  : table === stripeSubscriptions
                    ? subscriptionRows
                    : [],
            }),
          }),
        }),
      }),
      insert: (table: unknown) => ({
        values: (values: Record<string, unknown>) => ({
          returning: async () => {
            if (table !== adminPlanGrants) return [];
            const row = {
              id: "11111111-2222-4333-8444-555555555555",
              ...values,
              grantedByEmail: values.grantedByEmail ?? null,
              appliedAt: null,
              revokedAt: null,
              createdAt: new Date("2026-09-02T00:00:00.000Z"),
            };
            pendingGrantRows.push(row);
            return [row];
          },
        }),
      }),
      update: (table: unknown) => ({
        set: (values: Record<string, unknown>) => ({
          where: () => {
            const run = async () => {
              if (table === adminPlanGrants) {
                if (grantsTableMissing) {
                  throw Object.assign(new Error("Failed query"), { cause: { code: "42P01" } });
                }
                const hit = pendingGrantRows.filter((row) => !row.appliedAt && !row.revokedAt);
                for (const row of hit) Object.assign(row, values);
                return hit;
              }
              if (table === stripeSubscriptions) subscriptionUpdates.push(values);
              return [];
            };
            const promise = run();
            return Object.assign(promise, { returning: async () => await promise });
          },
        }),
      }),
  };
  // The lease helper owns the account_mutation_leases writes; everything else
  // goes to the recorders above.
  const leaseDb = withAccountMutationLeaseSupport(base);
  const composed = {
    ...leaseDb,
    insert: (table: unknown) =>
      table === accountMutationLeases ? leaseDb.insert(table) : base.insert(table),
    update: (table: unknown) =>
      table === accountMutationLeases ? leaseDb.update(table) : base.update(table),
    transaction: async <Result,>(operation: (tx: unknown) => Promise<Result>) =>
      await operation(composed),
  };
  return composed;
}

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: adminDbMock,
}));

const { GET, POST } = await import("../app/api/admin/users/route");
const { POST: POST_TEAMS } = await import("../app/api/admin/teams/route");
const { POST: POST_EMAIL_GRANTS, DELETE: DELETE_EMAIL_GRANTS } = await import(
  "../app/api/admin/email-grants/route"
);
const { POST: POST_SUBSCRIPTIONS } = await import("../app/api/admin/subscriptions/route");
const { GET: GET_PRO_USERS } = await import("../app/api/admin/pro-users/route");
const { GET: GET_PRO_SCAN } = await import("../app/api/admin/pro-users/scan/route");

const adminUser = () =>
  stackUser({ id: "admin-1", primaryEmail: "lawrence@manaflow.ai" });

function getRequest(query: string) {
  return new NextRequest(`https://cmux.com/api/admin/users?q=${encodeURIComponent(query)}`);
}

function postRequest(
  body: unknown,
  headers: Record<string, string> = {},
  path = "/api/admin/users",
  method: "POST" | "DELETE" = "POST",
) {
  return new NextRequest(`https://cmux.com${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      origin: "https://cmux.com",
      "sec-fetch-site": "same-origin",
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

describe("admin users route", () => {
  beforeEach(() => {
    stackConfigured = true;
    currentUser = adminUser();
    directory = [
      stackUser({ id: "u1", primaryEmail: "pat@example.com" }),
      stackUser({ id: "u2", primaryEmail: "sam@example.com", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } }),
    ];
    teamDirectory = [
      stackTeam({ id: "t1", displayName: "Acme" }),
      stackTeam({ id: "t2", displayName: "Pat Labs", clientReadOnlyMetadata: { cmuxVmPlan: "team" } }),
    ];
    pendingGrantRows = [];
    subscriptionRows = [];
    subscriptionUpdates = [];
    getUser.mockClear();
    listUsers.mockClear();
    getTeam.mockClear();
    listTeams.mockClear();
    stripeSubscriptionUpdate.mockClear();
  });

  test("GET returns 503 when Stack is not configured", async () => {
    stackConfigured = false;
    const response = await GET(getRequest("pat"));
    expect(response.status).toBe(503);
  });

  test("GET returns 401 for signed-out and anonymous callers", async () => {
    currentUser = null;
    expect((await GET(getRequest("pat"))).status).toBe(401);
    currentUser = stackUser({ id: "anon", primaryEmail: "lawrence@manaflow.ai", isAnonymous: true });
    expect((await GET(getRequest("pat"))).status).toBe(401);
    expect(listUsers).not.toHaveBeenCalled();
  });

  test("GET returns 403 for non-admin, lookalike, and unverified company callers", async () => {
    for (const user of [
      stackUser({ id: "user", primaryEmail: "pat@example.com" }),
      stackUser({ id: "lookalike", primaryEmail: "pat@manaflow.ai.evil.com" }),
      stackUser({ id: "subdomain", primaryEmail: "pat@sub.cmux.com" }),
      stackUser({ id: "unverified", primaryEmail: "impostor@manaflow.ai", primaryEmailVerified: false }),
      stackUser({ id: "unverified-cmux", primaryEmail: "impostor@cmux.com", primaryEmailVerified: false }),
      stackUser({ id: "no-email", primaryEmail: null }),
    ]) {
      currentUser = user;
      expect((await GET(getRequest("pat"))).status).toBe(403);
      expect((await POST(postRequest({ userId: "u1", plan: "pro" }))).status).toBe(403);
    }
    expect(listUsers).not.toHaveBeenCalled();
    expect(directory[0]?.updates).toEqual([]);
  });

  test("GET admits verified admins on every company domain", async () => {
    for (const email of ["a@cmux.com", "b@manaflow.ai", "c@manaflow.com"]) {
      currentUser = stackUser({ id: "admin", primaryEmail: email });
      expect((await GET(getRequest("pat"))).status).toBe(200);
    }
  });

  test("GET rejects short queries", async () => {
    const response = await GET(getRequest("p"));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_query" });
  });

  test("GET returns matching users, teams, and pending grants for admins", async () => {
    pendingGrantRows = [{
      id: "11111111-2222-4333-8444-555555555555",
      email: "sam.future@example.com",
      plan: "pro",
      grantedByUserId: "admin-1",
      grantedByEmail: "lawrence@manaflow.ai",
      appliedAt: null,
      revokedAt: null,
      createdAt: new Date("2026-09-02T00:00:00.000Z"),
    }];
    const response = await GET(getRequest("sam"));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = (await response.json()) as {
      users: Array<Record<string, unknown>>;
      teams: Array<Record<string, unknown>>;
      pendingGrants: Array<Record<string, unknown>>;
    };
    expect(body.users).toHaveLength(1);
    expect(body.users[0]).toMatchObject({
      id: "u2",
      email: "sam@example.com",
      isPro: true,
      manualPlanId: "pro",
      metadataPlanId: null,
      stripe: { subscriptionStatus: null, hasActiveSubscription: false },
      lastGrant: null,
    });
    expect(body.teams).toEqual([]);
    expect(body.pendingGrants).toHaveLength(1);
    expect(body.pendingGrants[0]).toMatchObject({ email: "sam.future@example.com", plan: "pro" });

    const teamResponse = await GET(getRequest("pat"));
    const teamBody = (await teamResponse.json()) as { teams: Array<Record<string, unknown>> };
    expect(teamBody.teams).toHaveLength(1);
    expect(teamBody.teams[0]).toMatchObject({ id: "t2", isTeam: true, manualPlanId: "team", memberCount: 2 });
  });

  test("POST rejects cross-site browser mutations before touching auth", async () => {
    const response = await POST(
      postRequest({ userId: "u1", plan: "pro" }, { "sec-fetch-site": "cross-site", origin: "https://evil.example" }),
    );
    expect(response.status).toBe(403);
    expect(getUser).not.toHaveBeenCalled();
  });

  test("POST returns 403 for non-admins", async () => {
    currentUser = stackUser({ id: "user", primaryEmail: "pat@example.com" });
    const response = await POST(postRequest({ userId: "u1", plan: "pro" }));
    expect(response.status).toBe(403);
    expect(directory[0]?.updates).toEqual([]);
  });

  test("POST validates the body", async () => {
    expect((await POST(postRequest({ userId: "u1", plan: "team" }))).status).toBe(400);
    expect((await POST(postRequest({ userId: "", plan: "pro" }))).status).toBe(400);
    expect((await POST(postRequest({ plan: "pro" }))).status).toBe(400);
    expect((await POST(postRequest("nope"))).status).toBe(400);
  });

  test("POST grants Pro and records the admin in server metadata", async () => {
    const response = await POST(postRequest({ userId: "u1", plan: "pro" }));
    expect(response.status).toBe(200);
    const body = (await response.json()) as { user: Record<string, unknown> };
    expect(body.user).toMatchObject({ id: "u1", isPro: true, manualPlanId: "pro" });
    const target = directory[0]!;
    expect(target.clientReadOnlyMetadata).toEqual({ cmuxVmPlan: "pro" });
    expect(target.serverMetadata.cmuxAdminPlanGrant).toMatchObject({
      plan: "pro",
      byUserId: "admin-1",
      byEmail: "lawrence@manaflow.ai",
    });
  });

  test("POST removes a grant", async () => {
    const response = await POST(postRequest({ userId: "u2", plan: null }));
    expect(response.status).toBe(200);
    const body = (await response.json()) as { user: Record<string, unknown> };
    expect(body.user).toMatchObject({ id: "u2", isPro: false, manualPlanId: null });
    expect(directory[1]?.clientReadOnlyMetadata).toEqual({});
  });

  test("POST returns 404 for an unknown user", async () => {
    const response = await POST(postRequest({ userId: "missing", plan: "pro" }));
    expect(response.status).toBe(404);
  });
});

describe("admin teams route", () => {
  beforeEach(() => {
    currentUser = adminUser();
    teamDirectory = [stackTeam({ id: "t1", displayName: "Acme" })];
  });

  test("rejects non-admins and bad bodies", async () => {
    currentUser = stackUser({ id: "user", primaryEmail: "pat@example.com" });
    expect((await POST_TEAMS(postRequest({ teamId: "t1", plan: "team" }, {}, "/api/admin/teams"))).status).toBe(403);
    currentUser = adminUser();
    expect((await POST_TEAMS(postRequest({ teamId: "t1", plan: "pro" }, {}, "/api/admin/teams"))).status).toBe(400);
    expect((await POST_TEAMS(postRequest({ plan: "team" }, {}, "/api/admin/teams"))).status).toBe(400);
    expect(teamDirectory[0]?.updates).toEqual([]);
  });

  test("grants and removes the team override", async () => {
    const granted = await POST_TEAMS(postRequest({ teamId: "t1", plan: "team" }, {}, "/api/admin/teams"));
    expect(granted.status).toBe(200);
    expect(((await granted.json()) as { team: Record<string, unknown> }).team).toMatchObject({
      id: "t1",
      isTeam: true,
      manualPlanId: "team",
    });
    expect(teamDirectory[0]?.clientReadOnlyMetadata).toEqual({ cmuxVmPlan: "team" });
    expect(teamDirectory[0]?.serverMetadata.cmuxAdminPlanGrant).toMatchObject({ plan: "team", byUserId: "admin-1" });

    const removed = await POST_TEAMS(postRequest({ teamId: "t1", plan: null }, {}, "/api/admin/teams"));
    expect(removed.status).toBe(200);
    expect(teamDirectory[0]?.clientReadOnlyMetadata).toEqual({});
    expect((await POST_TEAMS(postRequest({ teamId: "nope", plan: "team" }, {}, "/api/admin/teams"))).status).toBe(404);
  });
});

describe("admin email grants route", () => {
  beforeEach(() => {
    currentUser = adminUser();
    directory = [stackUser({ id: "u1", primaryEmail: "pat@example.com" })];
    pendingGrantRows = [];
  });

  test("grants directly when the email belongs to one existing user", async () => {
    const response = await POST_EMAIL_GRANTS(
      postRequest({ email: "Pat@Example.com", plan: "founders" }, {}, "/api/admin/email-grants"),
    );
    expect(response.status).toBe(200);
    expect(((await response.json()) as { user: Record<string, unknown> }).user).toMatchObject({
      id: "u1",
      manualPlanId: "founders",
    });
    expect(pendingGrantRows).toEqual([]);
  });

  test("keeps the grant pending when the only matching account is unverified", async () => {
    directory = [stackUser({ id: "u1", primaryEmail: "pat@example.com", primaryEmailVerified: false })];
    const response = await POST_EMAIL_GRANTS(
      postRequest({ email: "pat@example.com", plan: "pro" }, {}, "/api/admin/email-grants"),
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as { pendingGrant?: Record<string, unknown>; user?: unknown };
    expect(body.user).toBeUndefined();
    expect(body.pendingGrant).toMatchObject({ email: "pat@example.com", plan: "pro" });
    expect(directory[0]?.updates).toEqual([]);
  });

  test("records a pending grant for an unknown email and can revoke it", async () => {
    const response = await POST_EMAIL_GRANTS(
      postRequest({ email: "future@example.com", plan: "pro" }, {}, "/api/admin/email-grants"),
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as { pendingGrant: Record<string, unknown>; unclearedUserIds: string[] };
    expect(body.pendingGrant).toMatchObject({ email: "future@example.com", plan: "pro" });
    expect(body.pendingGrant).not.toHaveProperty("unclearedUserIds");
    expect(body.unclearedUserIds).toEqual([]);
    expect(pendingGrantRows).toHaveLength(1);
    expect(pendingGrantRows[0]).toMatchObject({ grantedByUserId: "admin-1", grantedByEmail: "lawrence@manaflow.ai" });

    const revoked = await DELETE_EMAIL_GRANTS(
      postRequest({ grantId: body.pendingGrant.id }, {}, "/api/admin/email-grants", "DELETE"),
    );
    expect(revoked.status).toBe(200);
    expect(pendingGrantRows[0]?.revokedAt).toBeInstanceOf(Date);
  });

  test("DELETE reports 503 when the grants table has not been migrated", async () => {
    grantsTableMissing = true;
    try {
      const response = await DELETE_EMAIL_GRANTS(
        postRequest({ grantId: "11111111-2222-4333-8444-555555555555" }, {}, "/api/admin/email-grants", "DELETE"),
      );
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: "grants_unavailable" });
    } finally {
      grantsTableMissing = false;
    }
  });

  test("rejects junk emails, bad plans, non-admins, and bad grant ids", async () => {
    expect((await POST_EMAIL_GRANTS(postRequest({ email: "nope", plan: "pro" }, {}, "/api/admin/email-grants"))).status).toBe(400);
    expect((await POST_EMAIL_GRANTS(postRequest({ email: "x@example.com", plan: "team" }, {}, "/api/admin/email-grants"))).status).toBe(400);
    expect((await DELETE_EMAIL_GRANTS(postRequest({ grantId: "1; drop" }, {}, "/api/admin/email-grants", "DELETE"))).status).toBe(400);
    currentUser = stackUser({ id: "user", primaryEmail: "pat@example.com" });
    expect((await POST_EMAIL_GRANTS(postRequest({ email: "x@example.com", plan: "pro" }, {}, "/api/admin/email-grants"))).status).toBe(403);
    expect(pendingGrantRows).toEqual([]);
  });
});

describe("admin subscriptions route", () => {
  beforeEach(() => {
    currentUser = adminUser();
    subscriptionRows = [{ id: "sub_1" }];
    subscriptionUpdates = [];
    stripeSubscriptionUpdate.mockClear();
  });

  test("cancels at period end and records the snapshot", async () => {
    const response = await POST_SUBSCRIPTIONS(
      postRequest({ scope: "user", ownerId: "u1", action: "cancel" }, {}, "/api/admin/subscriptions"),
    );
    expect(response.status).toBe(200);
    expect(stripeSubscriptionUpdate).toHaveBeenCalledWith("sub_1", { cancel_at_period_end: true });
    expect(subscriptionUpdates[0]).toMatchObject({ cancelAtPeriodEnd: true });

    const resumed = await POST_SUBSCRIPTIONS(
      postRequest({ scope: "team", ownerId: "t1", action: "resume" }, {}, "/api/admin/subscriptions"),
    );
    expect(resumed.status).toBe(200);
    expect(stripeSubscriptionUpdate).toHaveBeenLastCalledWith("sub_1", { cancel_at_period_end: false });
  });

  test("returns 404 without an active subscription and 403 for non-admins", async () => {
    subscriptionRows = [];
    expect((await POST_SUBSCRIPTIONS(postRequest({ scope: "user", ownerId: "u1", action: "cancel" }, {}, "/api/admin/subscriptions"))).status).toBe(404);
    expect((await POST_SUBSCRIPTIONS(postRequest({ scope: "org", ownerId: "u1", action: "cancel" }, {}, "/api/admin/subscriptions"))).status).toBe(400);
    currentUser = stackUser({ id: "user", primaryEmail: "pat@example.com" });
    expect((await POST_SUBSCRIPTIONS(postRequest({ scope: "user", ownerId: "u1", action: "cancel" }, {}, "/api/admin/subscriptions"))).status).toBe(403);
    expect(stripeSubscriptionUpdate).not.toHaveBeenCalled();
  });
});

describe("admin pro-users routes", () => {
  beforeEach(() => {
    currentUser = adminUser();
    subscriptionListRows = [
      { userId: "u1", subscriptionId: "sub_1", status: "active", cancelAtPeriodEnd: false, currentPeriodEnd: null, email: "pat@example.com" },
    ];
    directory = [stackUser({ id: "u9", primaryEmail: "granted@example.com", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } })];
    listUsers.mockClear();
  });

  test("the roster and the scan are admin-only and never cacheable", async () => {
    for (const user of [
      null,
      stackUser({ id: "user", primaryEmail: "pat@example.com" }),
      stackUser({ id: "impostor", primaryEmail: "x@manaflow.ai", primaryEmailVerified: false }),
      stackUser({ id: "anon", primaryEmail: "a@cmux.com", isAnonymous: true }),
    ]) {
      currentUser = user;
      const expected = user === null || user.isAnonymous ? 401 : 403;
      expect((await GET_PRO_USERS(new NextRequest("https://cmux.com/api/admin/pro-users"))).status).toBe(expected);
      expect((await GET_PRO_SCAN(new NextRequest("https://cmux.com/api/admin/pro-users/scan?kind=users"))).status).toBe(expected);
    }
    expect(listUsers).not.toHaveBeenCalled();
    currentUser = adminUser();
    const response = await GET_PRO_USERS(new NextRequest("https://cmux.com/api/admin/pro-users"));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = (await response.json()) as { subscribers: Array<Record<string, unknown>>; truncated: Record<string, boolean> };
    expect(body.subscribers).toEqual([
      { userId: "u1", email: "pat@example.com", subscriptionId: "sub_1", status: "active", cancelAtPeriodEnd: false, currentPeriodEnd: null },
    ]);
    expect(body.truncated).toEqual({ subscribers: false, teamSubscriptions: false, pendingGrants: false });
  });

  test("the scan validates its query and returns paid manual overrides", async () => {
    expect((await GET_PRO_SCAN(new NextRequest("https://cmux.com/api/admin/pro-users/scan"))).status).toBe(400);
    expect((await GET_PRO_SCAN(new NextRequest("https://cmux.com/api/admin/pro-users/scan?kind=nope"))).status).toBe(400);
    expect((await GET_PRO_SCAN(new NextRequest("https://cmux.com/api/admin/pro-users/scan?kind=users&cursor=a%20b"))).status).toBe(400);
    const response = await GET_PRO_SCAN(new NextRequest("https://cmux.com/api/admin/pro-users/scan?kind=users"));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = (await response.json()) as { rows: Array<Record<string, unknown>>; nextCursor: string | null };
    expect(body.rows.map((row) => [row.userId, row.plan])).toEqual([["u9", "pro"]]);
    expect(body.nextCursor).toBeNull();
  });
});
