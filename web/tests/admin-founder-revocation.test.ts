import { describe, expect, test } from "bun:test";

import type { AccountDeletionUserMutationLease } from "../services/account/deletionLock";
import { AccountMetadataUserUnavailableError } from "../services/account/metadataMutation";
import {
  AdminGrantConflictError,
  AdminUserNotFoundError,
  revokeFounderPurchaseAccess,
  setManualPlanGrant,
  type AdminStackApp,
  type AdminStackUser,
} from "../services/admin/proGrants";
import { AccountDeletionUserMutationInProgressError } from "../services/account/deletionLock";
import {
  FOUNDER_ADMIN_REVOCATION_KEY,
  FOUNDER_REVOKED_STATUS,
  activeFounderRows,
  founderAdminRevocationFromRaw,
  isAdminRevokedSubscriptionRaw,
  revokedFounderRaw,
  type FounderPurchaseStore,
} from "../services/billing/founderRevocation";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  highestPersonalPlanId,
  isFounderSubscriptionRow,
  type StripeBillingStatus,
} from "../services/billing/pro";

// In-memory model of a user's personal stripe_subscriptions rows. Billing
// status is derived from the rows the same way the database queries do:
// any active personal row grants its plan, and Founder rows are not
// recurring subscriptions.
type Row = { id: string; plan: string; status: string; raw: Record<string, unknown> };

function founderRow(id = "sub_founder"): Row {
  return { id, plan: "pro", status: "active", raw: { id, metadata: { founders_edition: "true" } } };
}

function recurringRow(id: string, plan: "pro" | "max", status = "active"): Row {
  return { id, plan, status, raw: { id, metadata: { app: "cmux", plan } } };
}

function fakeStore(rows: Row[]): FounderPurchaseStore & { revokeCalls: number } {
  const store = {
    revokeCalls: 0,
    async activeFounderPurchaseIds() {
      return activeFounderRows(rows).map((row) => row.id);
    },
    async revokeActiveFounderPurchases(_userId: string, revocation: { byUserId: string; byEmail: string | null; at: string }) {
      store.revokeCalls += 1;
      const hit = activeFounderRows(rows);
      for (const row of hit) {
        row.raw = revokedFounderRaw(row.raw, revocation, row.status);
        row.status = FOUNDER_REVOKED_STATUS;
      }
      return hit.map((row) => row.id);
    },
  };
  return store;
}

function billingFromRows(rows: Row[]): () => Promise<StripeBillingStatus> {
  return async () => {
    const active = rows.filter((row) => (ACTIVE_STRIPE_PRO_STATUSES as readonly string[]).includes(row.status));
    const activePlanId = highestPersonalPlanId(active.map((row) => row.plan));
    const recurring = active.filter((row) => !isFounderSubscriptionRow(row));
    return {
      customerId: rows.length ? "cus_1" : null,
      subscriptionStatus: recurring[0]?.status ?? null,
      subscriptionId: recurring[0]?.id ?? null,
      activePlanId,
      hasRecurringSubscription: recurring.length > 0,
      cancelAtPeriodEnd: false,
      hasCustomer: rows.length > 0,
      hasActiveSubscription: activePlanId !== null,
    };
  };
}

type FakeUser = AdminStackUser & { updates: unknown[] };

function fakeUser(overrides: Partial<AdminStackUser> & { id: string }): FakeUser {
  const user = {
    primaryEmail: `${overrides.id}@example.com`,
    primaryEmailVerified: true,
    displayName: null,
    isAnonymous: false,
    signedUpAt: new Date("2026-01-02T03:04:05.000Z"),
    clientReadOnlyMetadata: {},
    serverMetadata: {},
    ...overrides,
    updates: [] as unknown[],
    async update(options: { clientReadOnlyMetadata?: unknown; serverMetadata?: unknown }) {
      user.updates.push(options);
      if ("clientReadOnlyMetadata" in options) {
        (user as { clientReadOnlyMetadata: unknown }).clientReadOnlyMetadata = options.clientReadOnlyMetadata;
      }
      if ("serverMetadata" in options) {
        (user as { serverMetadata: unknown }).serverMetadata = options.serverMetadata;
      }
    },
  };
  return user as FakeUser;
}

function fakeApp(users: AdminStackUser[]): AdminStackApp {
  return {
    async getUser(id) {
      return users.find((user) => user.id === id) ?? null;
    },
    async listUsers(options) {
      const query = (options.query ?? "").toLowerCase();
      return users.filter((user) => (user.primaryEmail ?? "").includes(query));
    },
    async getTeam() {
      return null;
    },
    async listTeams() {
      return [];
    },
  };
}

const lease: AccountDeletionUserMutationLease = { refresh: async () => undefined };

function directMutation(app: AdminStackApp, log?: string[]) {
  return async <Result>(
    userId: string,
    operation: (user: AdminStackUser, lease: AccountDeletionUserMutationLease) => Promise<Result>,
  ): Promise<Result> => {
    log?.push("lease:start");
    const user = await app.getUser(userId);
    if (!user) throw new AccountMetadataUserUnavailableError(userId);
    try {
      return await operation(user, lease);
    } finally {
      log?.push("lease:end");
    }
  };
}

const admin = { id: "admin-1", primaryEmail: "admin@manaflow.ai" };

function setup(rows: Row[], metadata: Record<string, unknown>) {
  const target = fakeUser({ id: "u1", clientReadOnlyMetadata: metadata });
  const app = fakeApp([target]);
  const store = fakeStore(rows);
  const common = {
    targetUserId: "u1",
    admin,
    app,
    withFreshUser: directMutation(app),
    stripeBillingStatus: billingFromRows(rows),
    founderPurchases: store,
    now: () => new Date("2026-10-14T12:00:00.000Z"),
  };
  return { target, app, store, common };
}

describe("founder revocation helpers", () => {
  test("only active, unrevoked Founder rows are revocable", () => {
    const founder = founderRow();
    const synthetic = { id: "founders_cs_1", plan: "pro", status: "active", raw: {} };
    const recurring = recurringRow("sub_max", "max");
    const lapsedFounder = { ...founderRow("sub_old"), status: "canceled" };
    const revoked = {
      ...founderRow("sub_revoked"),
      raw: revokedFounderRaw(founderRow().raw, { byUserId: "a", byEmail: null, at: "t" }, "active"),
    };
    expect(activeFounderRows([founder, synthetic, recurring, lapsedFounder, revoked]).map((row) => row.id))
      .toEqual(["sub_founder", "founders_cs_1"]);
  });

  test("the marker is durable, readable, and keeps the provider payload", () => {
    const raw = revokedFounderRaw(
      { id: "sub_founder", status: "canceled", metadata: { founders_edition: "true" } },
      { byUserId: "admin-1", byEmail: "admin@manaflow.ai", at: "2026-10-14T12:00:00.000Z" },
      "active",
    );
    expect(raw.metadata).toEqual({ founders_edition: "true" });
    expect(raw.status).toBe("canceled");
    expect(isAdminRevokedSubscriptionRaw(raw)).toBe(true);
    expect(founderAdminRevocationFromRaw(raw)).toEqual({
      byUserId: "admin-1",
      byEmail: "admin@manaflow.ai",
      at: "2026-10-14T12:00:00.000Z",
      previousStatus: "active",
    });
    expect(Object.keys(raw)).toContain(FOUNDER_ADMIN_REVOCATION_KEY);
    expect(isAdminRevokedSubscriptionRaw({ metadata: { founders_edition: "true" } })).toBe(false);
    expect(isAdminRevokedSubscriptionRaw(null)).toBe(false);
  });
});

describe("revokeFounderPurchaseAccess", () => {
  test("revokes Founder-backed Pro and drops the cmuxPlan mirror immediately", async () => {
    const rows = [founderRow()];
    const { target, store, common } = setup(rows, { cmuxPlan: "pro" });

    const result = await revokeFounderPurchaseAccess(common);

    expect(result.revokedFounderPurchaseIds).toEqual(["sub_founder"]);
    expect(store.revokeCalls).toBe(1);
    expect(rows[0]?.status).toBe(FOUNDER_REVOKED_STATUS);
    expect(founderAdminRevocationFromRaw(rows[0]?.raw)).toEqual({
      byUserId: "admin-1",
      byEmail: "admin@manaflow.ai",
      at: "2026-10-14T12:00:00.000Z",
      previousStatus: "active",
    });
    expect(target.clientReadOnlyMetadata).toEqual({});
    expect(result.user?.isPro).toBe(false);
    expect(result.user?.metadataPlanId).toBeNull();
    expect(result.user?.stripe.hasActiveSubscription).toBe(false);
  });

  test("runs the revocation inside the account-mutation lease", async () => {
    const rows = [founderRow()];
    const { app, common } = setup(rows, { cmuxPlan: "pro" });
    const log: string[] = [];
    const store = fakeStore(rows);
    const wrapped: FounderPurchaseStore = {
      activeFounderPurchaseIds: store.activeFounderPurchaseIds,
      async revokeActiveFounderPurchases(userId, revocation) {
        log.push("revoke");
        return await store.revokeActiveFounderPurchases(userId, revocation);
      },
    };
    await revokeFounderPurchaseAccess({ ...common, founderPurchases: wrapped, withFreshUser: directMutation(app, log) });
    expect(log.slice(0, 3)).toEqual(["lease:start", "revoke", "lease:end"]);
  });

  test("reconciles cmuxPlan inside the same lease as the revocation", async () => {
    const rows = [founderRow()];
    const { app, target, common } = setup(rows, { cmuxPlan: "pro" });
    const log: string[] = [];
    const update = target.update.bind(target);
    target.update = async (options) => {
      log.push("metadata:update");
      await update(options);
    };
    await revokeFounderPurchaseAccess({ ...common, withFreshUser: directMutation(app, log) });
    // One lease, and the mirror write happens before it is released.
    expect(log).toEqual(["lease:start", "metadata:update", "lease:end"]);
    expect(target.clientReadOnlyMetadata).toEqual({});
  });

  test("reports the revoked rows as soon as they commit, even if a later step fails", async () => {
    const rows = [founderRow()];
    const { common } = setup(rows, { cmuxPlan: "pro" });
    const reported: string[][] = [];
    await expect(revokeFounderPurchaseAccess({
      ...common,
      stripeBillingStatus: async () => {
        throw new Error("billing read failed");
      },
      onFounderPurchasesRevoked: async (ids) => {
        reported.push([...ids]);
      },
    })).rejects.toThrow("billing read failed");
    expect(reported).toEqual([["sub_founder"]]);
    expect(rows[0]?.status).toBe(FOUNDER_REVOKED_STATUS);
  });

  test("a retry after a half-failed revoke still reconciles the stale mirror", async () => {
    // The first call revoked the row but failed before reconciling, leaving
    // cmuxPlan "pro" behind; the retry finds nothing to revoke.
    const rows = [{ ...founderRow(), status: "canceled" }];
    const { target, common } = setup(rows, { cmuxPlan: "pro" });
    const result = await revokeFounderPurchaseAccess(common);
    expect(result.revokedFounderPurchaseIds).toEqual([]);
    expect(target.clientReadOnlyMetadata).toEqual({});
  });

  test("without an active Founder row nothing changes", async () => {
    const rows = [{ ...founderRow(), status: "canceled" }];
    const { target, common } = setup(rows, { cmuxVmPlan: "pro", cmuxPlan: "pro" });
    const reported: string[][] = [];
    const result = await revokeFounderPurchaseAccess({
      ...common,
      onFounderPurchasesRevoked: async (ids) => {
        reported.push([...ids]);
      },
    });
    expect(result.revokedFounderPurchaseIds).toEqual([]);
    expect(reported).toEqual([]);
    expect(target.updates).toEqual([]);
    expect(target.clientReadOnlyMetadata).toEqual({ cmuxVmPlan: "pro", cmuxPlan: "pro" });
  });

  test("never touches a paying recurring subscription or a manual grant", async () => {
    const rows = [recurringRow("sub_max", "max"), founderRow()];
    const { target, common } = setup(rows, { cmuxPlan: "max", cmuxVmPlan: "pro" });
    const result = await revokeFounderPurchaseAccess(common);
    expect(result.revokedFounderPurchaseIds).toEqual(["sub_founder"]);
    expect(rows[0]).toEqual(recurringRow("sub_max", "max"));
    expect(target.clientReadOnlyMetadata).toEqual({ cmuxPlan: "max", cmuxVmPlan: "pro" });
    expect(result.user?.isPro).toBe(true);
    expect(result.user?.stripe.hasActiveSubscription).toBe(true);
  });

  test("an admin grant still restores Pro after the purchase was revoked", async () => {
    const rows = [founderRow()];
    const { common } = setup(rows, { cmuxPlan: "pro" });
    await revokeFounderPurchaseAccess(common);
    const regranted = await setManualPlanGrant({ ...common, plan: "founders" });
    expect(regranted.isPro).toBe(true);
    expect(regranted.manualPlanId).toBe("founders");
    expect(rows[0]?.status).toBe(FOUNDER_REVOKED_STATUS);
  });

  test("clearing a manual grant never revokes the Founder purchase", async () => {
    const rows = [founderRow()];
    const { store, common } = setup(rows, { cmuxVmPlan: "pro", cmuxPlan: "pro" });
    const row = await setManualPlanGrant({ ...common, plan: null });
    expect(store.revokeCalls).toBe(0);
    expect(rows[0]?.status).toBe("active");
    expect(row.isPro).toBe(true);
  });

  test("maps a missing user and a lease conflict", async () => {
    const { common } = setup([founderRow()], {});
    await expect(revokeFounderPurchaseAccess({ ...common, targetUserId: "missing" }))
      .rejects.toBeInstanceOf(AdminUserNotFoundError);
    await expect(revokeFounderPurchaseAccess({
      ...common,
      withFreshUser: async () => {
        throw new AccountDeletionUserMutationInProgressError("u1");
      },
    })).rejects.toBeInstanceOf(AdminGrantConflictError);
  });
});
