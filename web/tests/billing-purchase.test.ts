import { beforeEach, describe, expect, mock, test } from "bun:test";

import {
  accountDeletionTombstones,
  billingEmailClaims,
  stripeCustomers,
  stripeSubscriptions,
} from "../db/schema";

process.env.RESEND_API_KEY ??= "test-resend-key";
process.env.CMUX_FEEDBACK_FROM_EMAIL ??= "feedback@example.com";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID ??= "test-feedback-rate-limit";
process.env.STACK_SECRET_SERVER_KEY ??= "test-stack-secret";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID ??= "00000000-0000-4000-8000-000000000000";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY ??= "test-stack-publishable";

const { applySubscriptionUpdate, recordCheckoutCompletion } = await import(
  "../services/billing/purchase"
);

const inserts: Array<{ table: unknown; values: Record<string, unknown> }> = [];
const updates: Array<{ table: unknown; values: Record<string, unknown> }> = [];
const upsertUpdates: Array<{ table: unknown; values: Record<string, unknown> }> = [];
const insertErrorsByTable = new Map<unknown, unknown>();
let selectResults: unknown[][] = [];
let tombstoneSelectResults: unknown[][] = [];

function fakeDb() {
  const client = {
    insert: (table: unknown) => ({
      values: (values: Record<string, unknown>) => {
        inserts.push({ table, values });
        return {
          onConflictDoUpdate: (options?: { set?: Record<string, unknown> }) => {
            upsertUpdates.push({ table, values: options?.set ?? {} });
            const error = insertErrorsByTable.get(table);
            if (error) return Promise.reject(error);
            return Promise.resolve();
          },
          then: (resolve: (value: unknown) => void) => resolve(undefined),
        };
      },
    }),
    select: () => ({
      from: (table: unknown) => ({
        where: () => table === accountDeletionTombstones
          ? tombstoneSelectableResult()
          : selectableResult(),
      }),
    }),
    update: (table: unknown) => ({
      set: (values: Record<string, unknown>) => ({
        where: () => {
          updates.push({ table, values });
          return Promise.resolve();
        },
      }),
    }),
  };
  return {
    ...client,
    execute: async (_query?: unknown) => undefined,
    transaction: async <T>(
      callback: (tx: typeof client & { execute: (_query?: unknown) => Promise<void> }) => Promise<T>,
    ) => await callback({ ...client, execute: async (_query?: unknown) => undefined }),
  };
}

function selectableResult() {
  return {
    orderBy: () => selectableResult(),
    limit: () => Promise.resolve(selectResults.shift() ?? []),
  };
}

function tombstoneSelectableResult() {
  return {
    orderBy: () => tombstoneSelectableResult(),
    limit: () => Promise.resolve(tombstoneSelectResults.shift() ?? []),
  };
}

function checkoutInput(customerId = "cus_123") {
  return {
    session: {
      id: "cs_123",
      client_reference_id: "user_123",
      customer: customerId,
      customer_details: { email: "Buyer@Example.com" },
      subscription: "sub_123",
    },
    subscription: {
      id: "sub_123",
      customer: customerId,
      status: "active",
      metadata: { stackUserId: "user_123", app: "cmux" },
      cancel_at_period_end: false,
      items: {
        data: [
          {
            current_period_end: 1_800_000_000,
            price: { id: "price_123" },
          },
        ],
      },
    },
    customer: {
      id: customerId,
      deleted: false,
      email: "Buyer@Example.com",
    },
  };
}

function teamCheckoutInput(customerId = "cus_team", stackUserId?: string) {
  const metadata = {
    stackTeamId: "team_123",
    plan: "team",
    app: "cmux",
    ...(stackUserId ? { stackUserId } : {}),
  };
  return {
    session: {
      id: "cs_team",
      client_reference_id: "team_123",
      customer: customerId,
      customer_details: { email: "buyer@example.com" },
      subscription: "sub_team",
      metadata,
    },
    subscription: {
      id: "sub_team",
      customer: customerId,
      status: "active",
      metadata,
      cancel_at_period_end: false,
      items: {
        data: [
          {
            quantity: 4,
            current_period_end: 1_800_000_000,
            price: { id: "price_team" },
          },
        ],
      },
    },
    customer: {
      id: customerId,
      deleted: false,
      email: "buyer@example.com",
    },
  };
}

describe("recordCheckoutCompletion", () => {
  beforeEach(() => {
    inserts.length = 0;
    updates.length = 0;
    upsertUpdates.length = 0;
    insertErrorsByTable.clear();
    selectResults = [];
    tombstoneSelectResults = [];
  });

  test("attaches Stripe email to a purchaser without a primary email", async () => {
    const update = mock(async () => undefined);
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user } as never,
    });

    expect(update).toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
    });
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("blocks checkout completion while account deletion is in progress", async () => {
    const update = mock(async () => undefined);
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: null,
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      update,
    };

    await expect(
      recordCheckoutCompletion(checkoutInput() as never, {
        db: fakeDb() as never,
        stackApp: { getUser: async () => user } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "user_123",
      subscriptionId: "sub_123",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_123");
    expect(deleteCustomer).toHaveBeenCalledWith("cus_123");
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
    expect(update).not.toHaveBeenCalled();
  });

  test("does not recreate checkout billing rows after tombstoned Stack user is gone", async () => {
    const cancelSubscription = mock(async () => {
      throw { statusCode: 404, message: "No such subscription" };
    });
    const deleteCustomer = mock(async () => undefined);
    tombstoneSelectResults = [[{ status: "completed" }]];

    await expect(
      recordCheckoutCompletion(checkoutInput() as never, {
        db: fakeDb() as never,
        stackApp: { getUser: async () => null } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "user_123",
      subscriptionId: "sub_123",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_123");
    expect(deleteCustomer).toHaveBeenCalledWith("cus_123");
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
  });

  test("fails closed when checkout metadata points at a missing Stack user without a deletion tombstone", async () => {
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);

    await expect(
      recordCheckoutCompletion(checkoutInput() as never, {
        db: fakeDb() as never,
        stackApp: { getUser: async () => null } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).rejects.toThrow("Stack user not found for checkout completion: user_123");

    expect(cancelSubscription).not.toHaveBeenCalled();
    expect(deleteCustomer).not.toHaveBeenCalled();
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
  });

  test("syncs checkout metadata under a fresh account deletion lock", async () => {
    let transactionOpen = false;
    let lockCount = 0;
    const baseDb = fakeDb();
    const db = {
      ...baseDb,
      transaction: async <T>(
        callback: (tx: typeof baseDb & { execute: (_query?: unknown) => Promise<void> }) => Promise<T>,
      ) => {
        transactionOpen = true;
        try {
          return await callback({
            ...baseDb,
            execute: async (_query?: unknown) => {
              lockCount += 1;
            },
          });
        } finally {
          transactionOpen = false;
        }
      },
    };
    const update = mock(async () => {
      expect(transactionOpen).toBe(true);
      expect(lockCount).toBe(2);
    });
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: {},
      update,
    };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: db as never,
      stackApp: { getUser: async () => user } as never,
    });

    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
    expect(lockCount).toBe(2);
  });

  test("skips checkout metadata sync when deletion starts after checkout rows commit", async () => {
    const staleUpdate = mock(async () => undefined);
    const deletingUpdate = mock(async () => undefined);
    const staleUser = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: {},
      update: staleUpdate,
    };
    const deletingUser = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      update: deletingUpdate,
    };
    let getUserCalls = 0;
    const getUser = mock(async () => {
      getUserCalls += 1;
      return getUserCalls === 1 ? staleUser : deletingUser;
    });

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser } as never,
    });

    expect(getUser).toHaveBeenCalledTimes(2);
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(true);
    expect(staleUpdate).not.toHaveBeenCalled();
    expect(deletingUpdate).not.toHaveBeenCalled();
  });

  test("records an email claim instead of attaching an email owned by a different Stack user", async () => {
    const update = mock(async () => undefined);
    const listUsers = mock(async () => [
      { id: "other_user", primaryEmail: "BUYER@example.com" },
    ]);
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, listUsers } as never,
    });

    expect(listUsers).toHaveBeenCalledWith({
      query: "buyer@example.com",
      limit: 20,
      includeAnonymous: true,
      includeRestricted: true,
    });
    expect(update).not.toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
    });
    expect(
      inserts.some(
        (insert) =>
          insert.table === billingEmailClaims &&
          insert.values.email === "buyer@example.com" &&
          insert.values.stripeCustomerId === "cus_123" &&
          insert.values.stackUserId === "user_123" &&
          insert.values.plan === "pro",
      ),
    ).toBe(true);
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeSubscriptions &&
          insert.values.stackUserId === "user_123" &&
          insert.values.plan === "pro",
      ),
    ).toBe(true);
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("attaches Stripe email when the ownership lookup finds no exact owner", async () => {
    const update = mock(async () => undefined);
    const listUsers = mock(async () => [
      { id: "fuzzy_user", primaryEmail: "not-buyer@example.com" },
    ]);
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, listUsers } as never,
    });

    expect(update).toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
    });
    expect(inserts.some((insert) => insert.table === billingEmailClaims)).toBe(false);
  });

  test("does not record an email claim when the email is owned by the purchaser", async () => {
    const update = mock(async () => undefined);
    const listUsers = mock(async () => [
      { id: "user_123", primaryEmail: "buyer@example.com" },
    ]);
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, listUsers } as never,
    });

    expect(update).toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
    });
    expect(inserts.some((insert) => insert.table === billingEmailClaims)).toBe(false);
  });

  test("records an email claim when Stack reports the email is already used", async () => {
    const update = mock(async (options: unknown) => {
      if ("primaryEmail" in (options as Record<string, unknown>)) {
        throw new Error("CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE");
      }
    });
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user } as never,
    });

    expect(
      inserts.some(
        (insert) =>
          insert.table === billingEmailClaims &&
          insert.values.email === "buyer@example.com" &&
          insert.values.stackUserId === "user_123",
      ),
    ).toBe(true);
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("falls back to update/catch when the ownership lookup throws", async () => {
    const update = mock(async (options: unknown) => {
      if ("primaryEmail" in (options as Record<string, unknown>)) {
        throw new Error("CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE");
      }
    });
    const listUsers = mock(async () => {
      throw new Error("Stack lookup failed");
    });
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, listUsers } as never,
    });

    expect(update).toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
    });
    expect(
      inserts.some(
        (insert) =>
          insert.table === billingEmailClaims &&
          insert.values.email === "buyer@example.com" &&
          insert.values.stackUserId === "user_123",
      ),
    ).toBe(true);
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("does not duplicate an existing email claim on retry", async () => {
    const update = mock(async () => undefined);
    const listUsers = mock(async () => [
      { id: "other_user", primaryEmail: "buyer@example.com" },
    ]);
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };
    selectResults = [[], [], [], [{ id: "claim_1" }]];

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, listUsers } as never,
    });
    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, listUsers } as never,
    });

    expect(inserts.filter((insert) => insert.table === billingEmailClaims)).toHaveLength(1);
    expect(update).not.toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
    });
  });

  test("updates the Stripe customer id when the same Stack user repurchases", async () => {
    const update = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update,
    };
    selectResults = [[{ id: "cus_old" }]];

    await recordCheckoutCompletion(checkoutInput("cus_new") as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user } as never,
    });

    expect(
      updates.some(
        (entry) => entry.table === stripeCustomers && entry.values.id === "cus_new",
      ),
    ).toBe(true);
    expect(inserts.some((insert) => insert.table === stripeCustomers)).toBe(false);
  });

  test("updates the existing Stack user customer row when Drizzle wraps a unique violation", async () => {
    const update = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update,
    };
    selectResults = [[]];
    insertErrorsByTable.set(
      stripeCustomers,
      Object.assign(new Error("Failed query: insert into stripe_customers"), {
        cause: {
          code: "23505",
          constraint: "stripe_customers_stack_user_id_unique",
        },
      }),
    );

    await recordCheckoutCompletion(checkoutInput("cus_race") as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user } as never,
    });

    expect(
      updates.some(
        (entry) => entry.table === stripeCustomers && entry.values.id === "cus_race",
      ),
    ).toBe(true);
  });

  test("records Team checkout rows and syncs the Stack team entitlement", async () => {
    const updateTeam = mock(async () => undefined);
    const team = {
      id: "team_123",
      clientReadOnlyMetadata: {},
      update: updateTeam,
    };
    selectResults = [[{ stackUserId: "owner_123" }], []];

    const result = await recordCheckoutCompletion(teamCheckoutInput() as never, {
      db: fakeDb() as never,
      stackApp: {
        getUser: async () => ({
          id: "owner_123",
          primaryEmail: "owner@example.com",
          clientReadOnlyMetadata: {},
          update: mock(async () => undefined),
        }),
        getTeam: async () => team,
      } as never,
    });

    expect(result).toEqual({
      scope: "team",
      stackTeamId: "team_123",
      subscriptionId: "sub_team",
    });
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeCustomers &&
          insert.values.id === "cus_team" &&
          insert.values.stackUserId === "owner_123" &&
          insert.values.stackTeamId === "team_123",
      ),
    ).toBe(true);
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeSubscriptions &&
          insert.values.scope === "team" &&
          insert.values.plan === "team" &&
          insert.values.stackTeamId === "team_123" &&
          insert.values.seats === 4,
      ),
    ).toBe(true);
    expect(updateTeam).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "team" },
    });
  });

  test("preserves legacy Team checkout rows owned by the team id", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user for legacy team-owned checkout");
    });
    const updateTeam = mock(async () => undefined);
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    const team = {
      id: "team_123",
      clientReadOnlyMetadata: {},
      update: updateTeam,
    };
    selectResults = [
      [{ id: "cus_team", stackUserId: "team_123" }],
      [{ id: "cus_team", stackUserId: "team_123" }],
    ];

    const result = await recordCheckoutCompletion(teamCheckoutInput() as never, {
      db: fakeDb() as never,
      stackApp: {
        getUser,
        getTeam: async () => team,
      } as never,
      stripeClient: () => ({
        subscriptions: { cancel: cancelSubscription },
        customers: { del: deleteCustomer },
      }) as never,
    });

    expect(result).toEqual({
      scope: "team",
      stackTeamId: "team_123",
      subscriptionId: "sub_team",
    });
    expect(getUser).not.toHaveBeenCalled();
    expect(cancelSubscription).not.toHaveBeenCalled();
    expect(deleteCustomer).not.toHaveBeenCalled();
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeCustomers &&
          insert.values.id === "cus_team" &&
          insert.values.stackUserId === "team_123" &&
          insert.values.stackTeamId === "team_123",
      ),
    ).toBe(true);
    expect(updateTeam).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "team" },
    });
  });

  test("blocks Team checkout completion while the billing owner is deleting without deleting the team customer", async () => {
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    const owner = {
      id: "owner_123",
      primaryEmail: "owner@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      update: mock(async () => undefined),
    };
    selectResults = [[{ id: "cus_team", stackUserId: "owner_123" }], []];

    await expect(
      recordCheckoutCompletion(teamCheckoutInput() as never, {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => owner,
          getTeam: async () => {
            throw new Error("should not load Stack team for blocked Team checkout");
          },
        } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "owner_123",
      subscriptionId: "sub_team",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_team");
    expect(deleteCustomer).not.toHaveBeenCalled();
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
    expect(owner.update).not.toHaveBeenCalled();
  });

  test("deletes a new Team checkout customer when account deletion wins before a customer row exists", async () => {
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    const owner = {
      id: "owner_123",
      primaryEmail: "owner@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      update: mock(async () => undefined),
    };

    await expect(
      recordCheckoutCompletion(teamCheckoutInput("cus_team_new", "owner_123") as never, {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => owner,
          getTeam: async () => {
            throw new Error("should not load Stack team for blocked Team checkout");
          },
        } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "owner_123",
      subscriptionId: "sub_team",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_team");
    expect(deleteCustomer).toHaveBeenCalledWith("cus_team_new");
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
    expect(owner.update).not.toHaveBeenCalled();
  });

  test("cancels Team checkout completion when buyer ownership is missing", async () => {
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    selectResults = [[], []];

    await expect(
      recordCheckoutCompletion(teamCheckoutInput("cus_team_new") as never, {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => {
            throw new Error("should not load a Stack user without a checkout owner");
          },
          getTeam: async () => {
            throw new Error("should not sync Stack team without a checkout owner");
          },
        } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "team_123",
      subscriptionId: "sub_team",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_team");
    expect(deleteCustomer).toHaveBeenCalledWith("cus_team_new");
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
  });

  test("preserves an existing Team checkout customer when account deletion blocks a metadata-owned checkout", async () => {
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    const owner = {
      id: "owner_123",
      primaryEmail: "owner@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      update: mock(async () => undefined),
    };
    selectResults = [[{ id: "cus_team_existing", stackUserId: "owner_123" }], []];

    await expect(
      recordCheckoutCompletion(teamCheckoutInput("cus_team_existing", "owner_123") as never, {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => owner,
          getTeam: async () => {
            throw new Error("should not load Stack team for blocked Team checkout");
          },
        } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "owner_123",
      subscriptionId: "sub_team",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_team");
    expect(deleteCustomer).not.toHaveBeenCalled();
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
    expect(owner.update).not.toHaveBeenCalled();
  });

  test("deletes a new Team checkout customer when the existing team customer is different", async () => {
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    const owner = {
      id: "owner_123",
      primaryEmail: "owner@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      update: mock(async () => undefined),
    };
    selectResults = [[{ id: "cus_team_old", stackUserId: "owner_123" }], []];

    await expect(
      recordCheckoutCompletion(teamCheckoutInput("cus_team_new", "owner_123") as never, {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => owner,
          getTeam: async () => {
            throw new Error("should not load Stack team for blocked Team checkout");
          },
        } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "owner_123",
      subscriptionId: "sub_team",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_team");
    expect(deleteCustomer).toHaveBeenCalledWith("cus_team_new");
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
    expect(owner.update).not.toHaveBeenCalled();
  });

  test("clears Team metadata when a Team subscription lapses", async () => {
    const updateTeam = mock(async () => undefined);
    const team = {
      id: "team_123",
      clientReadOnlyMetadata: { cmuxPlan: "team", cmuxVmPlan: "pro" },
      update: updateTeam,
    };
    selectResults = [[{ stackUserId: "owner_123" }], [{ stackUserId: "owner_123" }], []];

    const result = await applySubscriptionUpdate(
      {
        id: "sub_team",
        customer: "cus_team",
        status: "canceled",
        metadata: { stackTeamId: "team_123", plan: "team", app: "cmux" },
        cancel_at_period_end: false,
        items: {
          data: [
            {
              quantity: 7,
              current_period_end: 1_800_000_000,
              price: { id: "price_team" },
            },
          ],
        },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => ({
            id: "owner_123",
            primaryEmail: "owner@example.com",
            clientReadOnlyMetadata: {},
            update: mock(async () => undefined),
          }),
          getTeam: async () => team,
        } as never,
      },
    );

    expect(result).toEqual({ scope: "team", stackTeamId: "team_123", isActive: false });
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeSubscriptions &&
          insert.values.scope === "team" &&
          insert.values.seats === 7,
      ),
    ).toBe(true);
    expect(updateTeam).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
    });
  });

  test("syncs legacy Team subscription webhooks whose customer owner is the team id", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user for legacy Team-owned billing rows");
    });
    const updateTeam = mock(async () => undefined);
    const team = {
      id: "team_123",
      clientReadOnlyMetadata: { cmuxPlan: "team", cmuxVmPlan: "pro" },
      update: updateTeam,
    };
    selectResults = [[{ stackUserId: "team_123" }], [{ stackUserId: "team_123" }]];

    const result = await applySubscriptionUpdate(
      {
        id: "sub_team",
        customer: "cus_team",
        status: "canceled",
        metadata: { stackTeamId: "team_123", plan: "team", app: "cmux" },
        cancel_at_period_end: false,
        items: {
          data: [
            {
              quantity: 7,
              current_period_end: 1_800_000_000,
              price: { id: "price_team" },
            },
          ],
        },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: {
          getUser,
          getTeam: async () => team,
        } as never,
      },
    );

    expect(result).toEqual({ scope: "team", stackTeamId: "team_123", isActive: false });
    expect(getUser).not.toHaveBeenCalled();
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeSubscriptions &&
          insert.values.scope === "team" &&
          insert.values.stackUserId === "team_123",
      ),
    ).toBe(true);
    expect(updateTeam).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
    });
  });

  test("skips Team subscription webhooks for deleted-account owner rows", async () => {
    const getTeam = mock(async () => {
      throw new Error("should not load Stack team for deleted account owner");
    });
    selectResults = [[{ stackUserId: "deleted-account" }]];

    const result = await applySubscriptionUpdate(
      {
        id: "sub_team",
        customer: "cus_team",
        status: "canceled",
        metadata: { stackTeamId: "team_123", plan: "team", app: "cmux" },
        cancel_at_period_end: false,
        items: {
          data: [
            {
              quantity: 7,
              current_period_end: 1_800_000_000,
              price: { id: "price_team" },
            },
          ],
        },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: {
          getTeam,
        } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getTeam).not.toHaveBeenCalled();
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("skips ownerless legacy Team subscription webhooks before writing rows", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user for ownerless Team subscription");
    });
    const getTeam = mock(async () => {
      throw new Error("should not load Stack team for ownerless Team subscription");
    });
    selectResults = [[], []];

    const result = await applySubscriptionUpdate(
      {
        id: "sub_team",
        customer: "cus_team",
        status: "active",
        metadata: { stackTeamId: "team_123", plan: "team", app: "cmux" },
        cancel_at_period_end: false,
        items: {
          data: [
            {
              quantity: 7,
              current_period_end: 1_800_000_000,
              price: { id: "price_team" },
            },
          ],
        },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser, getTeam } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).not.toHaveBeenCalled();
    expect(getTeam).not.toHaveBeenCalled();
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("skips Team subscription webhooks for tombstoned metadata owners before writing rows", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user after tombstone blocks Team subscription");
    });
    const getTeam = mock(async () => {
      throw new Error("should not load Stack team after tombstone blocks Team subscription");
    });
    selectResults = [[], [], [], []];
    tombstoneSelectResults = [[{ status: "pending", updatedAt: new Date() }]];

    const result = await applySubscriptionUpdate(
      {
        id: "sub_team",
        customer: "cus_team",
        status: "active",
        metadata: {
          stackTeamId: "team_123",
          stackUserId: "owner_123",
          plan: "team",
          app: "cmux",
        },
        cancel_at_period_end: false,
        items: {
          data: [
            {
              quantity: 7,
              current_period_end: 1_800_000_000,
              price: { id: "price_team" },
            },
          ],
        },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: {
          getUser,
          getTeam,
        } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).not.toHaveBeenCalled();
    expect(getTeam).not.toHaveBeenCalled();
    expect(inserts.some((insert) => insert.table === stripeCustomers)).toBe(false);
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeCustomers)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("removes a user from TestFlight when a user Pro subscription lapses", async () => {
    const update = mock(async () => undefined);
    const removeTester = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update,
    };
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser: async () => user } as never,
        testflight: {
          isAscConfigured: () => true,
          removeTester,
        },
      },
    );

    expect(result).toEqual({ scope: "user", stackUserId: "user_123", isActive: false });
    expect(removeTester).toHaveBeenCalledWith("buyer@example.com");
    expect(updates.find((entry) => entry.table === stripeSubscriptions)?.values).not.toHaveProperty(
      "id",
    );
    expect(update).toHaveBeenCalledWith({ clientReadOnlyMetadata: {} });
  });

  test("does not fail the webhook when TestFlight removal fails", async () => {
    const captureAscError = mock(() => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update: mock(async () => undefined),
    };
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser: async () => user } as never,
        testflight: {
          isAscConfigured: () => true,
          removeTester: async () => {
            throw new Error("ASC down");
          },
          captureAscError,
        },
      },
    );

    expect(result).toEqual({ scope: "user", stackUserId: "user_123", isActive: false });
    expect(captureAscError).toHaveBeenCalledWith(
      expect.objectContaining({ message: "ASC down" }),
      expect.objectContaining({
        route: "/api/stripe/webhook",
        stackUserId: "user_123",
        email: "buyer@example.com",
      }),
    );
  });

  test("does not remove TestFlight access when ASC is unconfigured", async () => {
    const removeTester = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update: mock(async () => undefined),
    };
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];

    await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser: async () => user } as never,
        testflight: {
          isAscConfigured: () => false,
          removeTester,
        },
      },
    );

    expect(removeTester).not.toHaveBeenCalled();
  });

  test("skips user subscription webhooks while account deletion is in progress", async () => {
    const getUser = mock(async () => ({
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true, cmuxPlan: "pro" },
      update: mock(async () => undefined),
    }));
    selectResults = [[], []];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).toHaveBeenCalledWith("user_123");
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("skips known subscription webhooks before writing rows while account deletion is in progress", async () => {
    const update = mock(async () => undefined);
    const getUser = mock(async () => ({
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true, cmuxPlan: "pro" },
      update,
    }));
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).toHaveBeenCalledWith("user_123");
    expect(update).not.toHaveBeenCalled();
    expect(updates.some((entry) => entry.table === stripeSubscriptions)).toBe(false);
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
  });

  test("skips user subscription webhooks when deletion starts before the locked write", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user after tombstone blocks subscription write");
    });
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];
    tombstoneSelectResults = [[{ status: "pending", updatedAt: new Date() }]];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).not.toHaveBeenCalled();
    expect(updates.some((entry) => entry.table === stripeSubscriptions)).toBe(false);
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
  });

  test("skips subscription metadata sync when deletion starts after webhook rows update", async () => {
    const staleUpdate = mock(async () => undefined);
    const deletingUpdate = mock(async () => undefined);
    const staleUser = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update: staleUpdate,
    };
    const deletingUser = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true, cmuxPlan: "pro" },
      update: deletingUpdate,
    };
    let getUserCalls = 0;
    const getUser = mock(async () => {
      getUserCalls += 1;
      return getUserCalls === 1 ? staleUser : deletingUser;
    });
    selectResults = [[], []];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ scope: "user", stackUserId: "user_123", isActive: false });
    expect(getUser).toHaveBeenCalledTimes(2);
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(true);
    expect(staleUpdate).not.toHaveBeenCalled();
    expect(deletingUpdate).not.toHaveBeenCalled();
  });

  test("fails known subscription webhooks when the Stack user is missing", async () => {
    const getUser = mock(async () => null);
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];

    await expect(
      applySubscriptionUpdate(
        userSubscriptionUpdate({ status: "canceled" }) as never,
        {
          db: fakeDb() as never,
          stackApp: { getUser } as never,
        },
      ),
    ).rejects.toThrow("Stack user not found for Stripe subscription update: user_123");

    expect(getUser).toHaveBeenCalledWith("user_123");
    expect(updates.some((entry) => entry.table === stripeSubscriptions)).toBe(false);
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
  });

  test("skips metadata-only user subscription webhooks after local account rows are gone", async () => {
    const getUser = mock(async () => null);
    selectResults = [[], []];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).toHaveBeenCalledWith("user_123");
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("skips user subscription webhooks for anonymized local customer rows", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user for anonymized local customer");
    });
    selectResults = [[{ stackUserId: "deleted-account" }]];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "active" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).not.toHaveBeenCalled();
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("skips user subscription webhooks when Stripe metadata conflicts with the local customer mapping", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user for conflicting Stripe identity");
    });
    selectResults = [[{ stackUserId: "user_local" }]];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "active" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).not.toHaveBeenCalled();
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("creates a missing user subscription row from Stripe metadata", async () => {
    const update = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: {},
      update,
    };
    selectResults = [[], []];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "active" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser: async () => user } as never,
      },
    );

    expect(result).toEqual({ scope: "user", stackUserId: "user_123", isActive: true });
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeSubscriptions &&
          insert.values.id === "sub_user" &&
          insert.values.scope === "user" &&
          insert.values.stackUserId === "user_123",
      ),
    ).toBe(true);
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("creates a missing user subscription row when the customer mapping already exists", async () => {
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: {},
      update: mock(async () => undefined),
    };
    selectResults = [[{ stackUserId: "user_123" }], []];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "active" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser: async () => user } as never,
      },
    );

    expect(result).toEqual({ scope: "user", stackUserId: "user_123", isActive: true });
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeSubscriptions &&
          insert.values.id === "sub_user" &&
          insert.values.scope === "user" &&
          insert.values.stackUserId === "user_123",
      ),
    ).toBe(true);
    expect(
      upsertUpdates.find((entry) => entry.table === stripeSubscriptions)?.values,
    ).not.toHaveProperty("id");
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("does not remove TestFlight access when a Team subscription lapses", async () => {
    const removeTester = mock(async () => undefined);
    const team = {
      id: "team_123",
      clientReadOnlyMetadata: { cmuxPlan: "team" },
      update: mock(async () => undefined),
    };
    selectResults = [[{ stackUserId: "owner_123" }], [{ stackUserId: "owner_123" }], []];

    const result = await applySubscriptionUpdate(
      {
        id: "sub_team",
        customer: "cus_team",
        status: "canceled",
        metadata: { stackTeamId: "team_123", plan: "team", app: "cmux" },
        cancel_at_period_end: false,
        items: {
          data: [
            {
              quantity: 7,
              current_period_end: 1_800_000_000,
              price: { id: "price_team" },
            },
          ],
        },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => ({
            id: "owner_123",
            primaryEmail: "owner@example.com",
            clientReadOnlyMetadata: {},
            update: mock(async () => undefined),
          }),
          getTeam: async () => team,
        } as never,
        testflight: {
          isAscConfigured: () => true,
          removeTester,
        },
      },
    );

    expect(result).toEqual({ scope: "team", stackTeamId: "team_123", isActive: false });
    expect(removeTester).not.toHaveBeenCalled();
  });

  test("skips foreign subscription updates even when they carry a stackUserId", async () => {
    const result = await applySubscriptionUpdate(
      {
        id: "sub_foreign",
        customer: "cus_foreign",
        status: "active",
        metadata: { stackUserId: "user_123", app: "other" },
        cancel_at_period_end: false,
        items: { data: [{ current_period_end: 1_800_000_000, price: { id: "price_123" } }] },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser: async () => {
          throw new Error("should not load Stack user");
        } } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
  });
});

function userSubscriptionUpdate({ status }: { status: string }) {
  return {
    id: "sub_user",
    customer: "cus_user",
    status,
    metadata: { stackUserId: "user_123", plan: "pro", app: "cmux" },
    cancel_at_period_end: false,
    items: {
      data: [
        {
          current_period_end: 1_800_000_000,
          price: { id: "price_123" },
        },
      ],
    },
  };
}
