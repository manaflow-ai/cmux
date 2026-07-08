import { beforeEach, describe, expect, mock, test } from "bun:test";

import { billingEmailClaims, stripeCustomers, stripeSubscriptions } from "../db/schema";

mock.module("../app/lib/stack", () => ({
  stackServerApp: null,
}));
mock.module("../db/client", () => ({
  cloudDb: () => {
    throw new Error("test must inject a billing DB");
  },
}));
mock.module("../services/asc/client", () => ({
  isAscConfigured: () => false,
}));
mock.module("../services/asc/testflight", () => ({
  removeTester: async () => {},
}));
mock.module("../services/errors", () => ({
  captureAscError: () => {},
}));

const { applySubscriptionUpdate, recordCheckoutCompletion } = await import(
  "../services/billing/purchase"
);

const inserts: Array<{ table: unknown; values: Record<string, unknown> }> = [];
const updates: Array<{ table: unknown; values: Record<string, unknown> }> = [];
const insertErrorsByTable = new Map<unknown, unknown>();
let selectResults: unknown[][] = [];

function fakeDb() {
  return {
    insert: (table: unknown) => ({
      values: (values: Record<string, unknown>) => {
        inserts.push({ table, values });
        return {
          onConflictDoUpdate: () => {
            const error = insertErrorsByTable.get(table);
            if (error) return Promise.reject(error);
            return Promise.resolve();
          },
          then: (resolve: (value: unknown) => void) => resolve(undefined),
        };
      },
    }),
    select: () => ({
      from: () => ({
        where: () => selectableResult(),
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
}

function selectableResult() {
  return {
    orderBy: () => selectableResult(),
    limit: () => Promise.resolve(selectResults.shift() ?? []),
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

function teamCheckoutInput(customerId = "cus_team") {
  return {
    session: {
      id: "cs_team",
      client_reference_id: "team_123",
      customer: customerId,
      customer_details: { email: "buyer@example.com" },
      subscription: "sub_team",
      metadata: { stackTeamId: "team_123", plan: "team", app: "cmux" },
    },
    subscription: {
      id: "sub_team",
      customer: customerId,
      status: "active",
      metadata: { stackTeamId: "team_123", plan: "team", app: "cmux" },
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
    insertErrorsByTable.clear();
    selectResults = [];
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
        getUser: async () => {
          throw new Error("should not load Stack user for Team checkout");
        },
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

  test("clears Team metadata when a Team subscription lapses", async () => {
    const updateTeam = mock(async () => undefined);
    const team = {
      id: "team_123",
      clientReadOnlyMetadata: { cmuxPlan: "team", cmuxVmPlan: "pro" },
      update: updateTeam,
    };
    selectResults = [[{ stackUserId: "owner_123" }], []];

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
          getUser: async () => {
            throw new Error("should not load Stack user for Team subscription");
          },
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

  test("removes a user from TestFlight when a user Pro subscription lapses", async () => {
    const update = mock(async () => undefined);
    const removeTester = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update,
    };
    selectResults = [[{ stackUserId: "user_123" }]];

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
    selectResults = [[{ stackUserId: "user_123" }]];

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
    selectResults = [[{ stackUserId: "user_123" }]];

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

  test("skips user subscription webhooks after local billing rows are gone", async () => {
    const getUser = mock(async () => ({
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
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
    expect(getUser).not.toHaveBeenCalled();
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("does not remove TestFlight access when a Team subscription lapses", async () => {
    const removeTester = mock(async () => undefined);
    const team = {
      id: "team_123",
      clientReadOnlyMetadata: { cmuxPlan: "team" },
      update: mock(async () => undefined),
    };
    selectResults = [[{ stackUserId: "owner_123" }], []];

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
          getUser: async () => {
            throw new Error("should not load Stack user for Team subscription");
          },
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
