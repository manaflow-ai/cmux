import { beforeEach, describe, expect, mock, test } from "bun:test";

import { billingEmailClaims, stripeCustomers } from "../db/schema";
import {
  applySubscriptionUpdate,
  recordCheckoutCompletion,
} from "../services/billing/purchase";

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

  test("does not duplicate an existing email claim on retry", async () => {
    const update = mock(async (options: unknown) => {
      if ("primaryEmail" in (options as Record<string, unknown>)) throw new Error("email already used");
    });
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };
    selectResults = [[], [], [], [{ id: "claim_1" }]];

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user } as never,
    });
    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user } as never,
    });

    expect(inserts.filter((insert) => insert.table === billingEmailClaims)).toHaveLength(1);
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
