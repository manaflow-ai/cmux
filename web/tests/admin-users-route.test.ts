import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

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

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser, listUsers }),
  isStackConfigured: () => stackConfigured,
  promoteStackUserFromAnonymousViaApi: async () => undefined,
  stackServerApp: { getUser, listUsers },
}));

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () =>
    withAccountMutationLeaseSupport({
      select: () => ({
        from: () => ({
          where: () => ({
            limit: async () => [],
          }),
        }),
      }),
    }),
}));

const { GET, POST } = await import("../app/api/admin/users/route");

const adminUser = () =>
  stackUser({ id: "admin-1", primaryEmail: "lawrence@manaflow.ai" });

function getRequest(query: string) {
  return new NextRequest(`https://cmux.com/api/admin/users?q=${encodeURIComponent(query)}`);
}

function postRequest(body: unknown, headers: Record<string, string> = {}) {
  return new NextRequest("https://cmux.com/api/admin/users", {
    method: "POST",
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
    getUser.mockClear();
    listUsers.mockClear();
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

  test("GET returns matching users with access state for admins", async () => {
    const response = await GET(getRequest("sam"));
    expect(response.status).toBe(200);
    const body = (await response.json()) as { users: Array<Record<string, unknown>> };
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
