import { describe, expect, test } from "bun:test";

import {
  AccountDeletionMutationBlockedError,
  AccountDeletionUserMutationInProgressError,
  type AccountDeletionUserMutationLease,
} from "../services/account/deletionLock";
import { AccountMetadataUserUnavailableError } from "../services/account/metadataMutation";
import {
  AdminGrantConflictError,
  AdminUserNotFoundError,
  adminUserRow,
  grantRecordFromServerMetadata,
  isAdminGrantablePlanId,
  searchAdminUsers,
  setManualPlanGrant,
  type AdminStackApp,
  type AdminStackUser,
} from "../services/admin/proGrants";
import type { StripeBillingStatus } from "../services/billing/pro";

type FakeUser = AdminStackUser & {
  readonly updates: Array<{ clientReadOnlyMetadata?: unknown; serverMetadata?: unknown }>;
};

function fakeUser(
  overrides: Partial<Omit<AdminStackUser, "update">> & { id: string },
): FakeUser {
  const updates: FakeUser["updates"] = [];
  const user = {
    primaryEmail: `${overrides.id}@example.com`,
    primaryEmailVerified: true,
    displayName: null,
    isAnonymous: false,
    signedUpAt: new Date("2026-01-02T03:04:05.000Z"),
    clientReadOnlyMetadata: {},
    serverMetadata: {},
    ...overrides,
    updates,
    async update(options: { clientReadOnlyMetadata?: unknown; serverMetadata?: unknown }) {
      updates.push(options);
      if ("clientReadOnlyMetadata" in options) {
        (user as { clientReadOnlyMetadata: unknown }).clientReadOnlyMetadata =
          options.clientReadOnlyMetadata;
      }
      if ("serverMetadata" in options) {
        (user as { serverMetadata: unknown }).serverMetadata = options.serverMetadata;
      }
    },
  };
  return user as FakeUser;
}

function fakeApp(users: readonly AdminStackUser[]): AdminStackApp & {
  readonly listCalls: unknown[];
} {
  const listCalls: unknown[] = [];
  return {
    listCalls,
    async getUser(userId) {
      return users.find((user) => user.id === userId) ?? null;
    },
    async listUsers(options) {
      listCalls.push(options);
      const query = (options.query ?? "").toLowerCase();
      return users.filter((user) =>
        user.id === query ||
        (user.primaryEmail ?? "").toLowerCase().includes(query) ||
        (user.displayName ?? "").toLowerCase().includes(query),
      );
    },
  };
}

const noStripe: StripeBillingStatus = {
  customerId: null,
  subscriptionStatus: null,
  cancelAtPeriodEnd: false,
  hasCustomer: false,
  hasActiveSubscription: false,
};
const activeStripe: StripeBillingStatus = {
  customerId: "cus_1",
  subscriptionStatus: "active",
  cancelAtPeriodEnd: false,
  hasCustomer: true,
  hasActiveSubscription: true,
};

const lease: AccountDeletionUserMutationLease = { refresh: async () => undefined };

function directMutation(app: AdminStackApp) {
  return async <Result>(
    userId: string,
    operation: (user: AdminStackUser, lease: AccountDeletionUserMutationLease) => Promise<Result>,
  ): Promise<Result> => {
    const user = await app.getUser(userId);
    if (!user) throw new AccountMetadataUserUnavailableError(userId);
    return await operation(user, lease);
  };
}

const admin = { id: "admin-1", primaryEmail: "lawrence@manaflow.ai" };

describe("isAdminGrantablePlanId", () => {
  test("accepts pro and founders only", () => {
    expect(isAdminGrantablePlanId("pro")).toBe(true);
    expect(isAdminGrantablePlanId("founders")).toBe(true);
    expect(isAdminGrantablePlanId("team")).toBe(false);
    expect(isAdminGrantablePlanId("free")).toBe(false);
    expect(isAdminGrantablePlanId("")).toBe(false);
    expect(isAdminGrantablePlanId(null)).toBe(false);
  });
});

describe("adminUserRow", () => {
  test("reports Pro from a Stripe subscription", () => {
    const row = adminUserRow(fakeUser({ id: "u1", clientReadOnlyMetadata: { cmuxPlan: "pro" } }), activeStripe);
    expect(row.isPro).toBe(true);
    expect(row.manualPlanId).toBeNull();
    expect(row.metadataPlanId).toBe("pro");
    expect(row.stripe.hasActiveSubscription).toBe(true);
    expect(row.signedUpAt).toBe("2026-01-02T03:04:05.000Z");
  });

  test("reports Pro from a paid manual grant without Stripe", () => {
    expect(adminUserRow(fakeUser({ id: "u1", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } }), noStripe).isPro).toBe(true);
    expect(adminUserRow(fakeUser({ id: "u1", clientReadOnlyMetadata: { cmuxVmPlan: "Founders" } }), noStripe).isPro).toBe(true);
    expect(adminUserRow(fakeUser({ id: "u1", clientReadOnlyMetadata: { cmuxVmPlan: "free" } }), noStripe).isPro).toBe(false);
    expect(adminUserRow(fakeUser({ id: "u1", clientReadOnlyMetadata: { cmuxVmPlan: "enterprise" } }), noStripe).isPro).toBe(false);
    expect(adminUserRow(fakeUser({ id: "u1" }), noStripe).isPro).toBe(false);
  });

  test("surfaces the last grant from server metadata", () => {
    const row = adminUserRow(
      fakeUser({
        id: "u1",
        serverMetadata: {
          cmuxAdminPlanGrant: { plan: "pro", byUserId: "admin-1", byEmail: "lawrence@manaflow.ai", at: "2026-09-02T00:00:00.000Z" },
        },
      }),
      noStripe,
    );
    expect(row.lastGrant).toEqual({
      plan: "pro",
      byUserId: "admin-1",
      byEmail: "lawrence@manaflow.ai",
      at: "2026-09-02T00:00:00.000Z",
    });
    expect(grantRecordFromServerMetadata({ cmuxAdminPlanGrant: "nope" })).toBeNull();
    expect(grantRecordFromServerMetadata({ cmuxAdminPlanGrant: { plan: "pro" } })).toBeNull();
    expect(grantRecordFromServerMetadata(null)).toBeNull();
  });
});

describe("searchAdminUsers", () => {
  test("requires at least two characters", async () => {
    const app = fakeApp([fakeUser({ id: "u1" })]);
    expect(await searchAdminUsers(" a ", { app, stripeBillingStatus: async () => noStripe })).toEqual([]);
    expect(app.listCalls).toEqual([]);
  });

  test("lists non-anonymous matches with billing state", async () => {
    const app = fakeApp([
      fakeUser({ id: "u1", primaryEmail: "pat@example.com", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } }),
      fakeUser({ id: "u2", primaryEmail: "pat-anon@example.com", isAnonymous: true }),
      fakeUser({ id: "u3", primaryEmail: "other@example.com" }),
    ]);
    const rows = await searchAdminUsers("pat", {
      app,
      stripeBillingStatus: async (userId) => (userId === "u3" ? activeStripe : noStripe),
    });
    expect(rows.map((row) => row.id)).toEqual(["u1"]);
    expect(rows[0]?.isPro).toBe(true);
    expect(app.listCalls).toEqual([
      { query: "pat", limit: 25, includeAnonymous: false, includeRestricted: true },
    ]);
  });
});

describe("setManualPlanGrant", () => {
  test("grants pro by writing cmuxVmPlan and an audit record", async () => {
    const target = fakeUser({ id: "u1", clientReadOnlyMetadata: { cmuxPlan: "free", other: 1 } });
    const app = fakeApp([target]);
    const row = await setManualPlanGrant({
      targetUserId: "u1",
      plan: "pro",
      admin,
      app,
      now: () => new Date("2026-09-02T10:00:00.000Z"),
      withFreshUser: directMutation(app),
      stripeBillingStatus: async () => noStripe,
    });
    expect(target.updates).toHaveLength(1);
    expect(target.updates[0]).toEqual({
      clientReadOnlyMetadata: { cmuxPlan: "free", other: 1, cmuxVmPlan: "pro" },
      serverMetadata: {
        cmuxAdminPlanGrant: {
          plan: "pro",
          byUserId: "admin-1",
          byEmail: "lawrence@manaflow.ai",
          at: "2026-09-02T10:00:00.000Z",
        },
      },
    });
    expect(row.isPro).toBe(true);
    expect(row.manualPlanId).toBe("pro");
    expect(row.lastGrant?.plan).toBe("pro");
  });

  test("removing the grant deletes cmuxVmPlan and reconciles cmuxPlan from Stripe", async () => {
    const target = fakeUser({
      id: "u1",
      clientReadOnlyMetadata: { cmuxVmPlan: "pro", cmuxPlan: "pro" },
    });
    const app = fakeApp([target]);
    const row = await setManualPlanGrant({
      targetUserId: "u1",
      plan: null,
      admin,
      app,
      withFreshUser: directMutation(app),
      stripeBillingStatus: async () => noStripe,
    });
    // First write clears the override; the resolver then drops the stale
    // cmuxPlan mirror because there is no Stripe subscription behind it.
    expect(target.updates[0]?.clientReadOnlyMetadata).toEqual({ cmuxPlan: "pro" });
    expect(target.clientReadOnlyMetadata).toEqual({});
    expect(row.isPro).toBe(false);
    expect(row.manualPlanId).toBeNull();
    expect(row.metadataPlanId).toBeNull();
    expect(row.lastGrant?.plan).toBeNull();
  });

  test("removing the grant keeps Pro for a Stripe subscriber", async () => {
    const target = fakeUser({
      id: "u1",
      clientReadOnlyMetadata: { cmuxVmPlan: "founders", cmuxPlan: "pro" },
    });
    const app = fakeApp([target]);
    const row = await setManualPlanGrant({
      targetUserId: "u1",
      plan: null,
      admin,
      app,
      withFreshUser: directMutation(app),
      stripeBillingStatus: async () => activeStripe,
    });
    expect(target.updates).toHaveLength(1);
    expect(target.clientReadOnlyMetadata).toEqual({ cmuxPlan: "pro" });
    expect(row.isPro).toBe(true);
    expect(row.manualPlanId).toBeNull();
  });

  test("maps a missing user to AdminUserNotFoundError", async () => {
    const app = fakeApp([]);
    await expect(
      setManualPlanGrant({
        targetUserId: "missing",
        plan: "pro",
        admin,
        app,
        withFreshUser: directMutation(app),
        stripeBillingStatus: async () => noStripe,
      }),
    ).rejects.toBeInstanceOf(AdminUserNotFoundError);
  });

  test("refuses anonymous targets", async () => {
    const target = fakeUser({ id: "anon", isAnonymous: true });
    const app = fakeApp([target]);
    await expect(
      setManualPlanGrant({
        targetUserId: "anon",
        plan: "pro",
        admin,
        app,
        withFreshUser: directMutation(app),
        stripeBillingStatus: async () => noStripe,
      }),
    ).rejects.toBeInstanceOf(AdminUserNotFoundError);
    expect(target.updates).toEqual([]);
  });

  test("maps deletion and lease conflicts to AdminGrantConflictError", async () => {
    const app = fakeApp([fakeUser({ id: "u1" })]);
    for (const error of [
      new AccountDeletionMutationBlockedError("u1"),
      new AccountDeletionUserMutationInProgressError("u1"),
    ]) {
      await expect(
        setManualPlanGrant({
          targetUserId: "u1",
          plan: "pro",
          admin,
          app,
          withFreshUser: async () => {
            throw error;
          },
          stripeBillingStatus: async () => noStripe,
        }),
      ).rejects.toBeInstanceOf(AdminGrantConflictError);
    }
  });
});
