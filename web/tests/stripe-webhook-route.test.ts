import { beforeEach, describe, expect, mock, test } from "bun:test";

import { makeStripeWebhookHandler } from "../app/api/stripe/webhook/route";

let currentEvent: Record<string, unknown>;
let constructThrows = false;
let insertedEventRows: unknown[] = [{ id: "evt_1" }];
let selectedEventRows: unknown[] = [];
const updates: Record<string, unknown>[] = [];
let recordCheckoutShouldFail = false;
let recordCheckoutCompletionResult: unknown = {
  scope: "user",
  stackUserId: "user_1",
  subscriptionId: "sub_1",
};
const recordCheckoutCompletion = mock(async () => {
  if (recordCheckoutShouldFail) throw new Error("db down");
  return recordCheckoutCompletionResult;
});
const applySubscriptionUpdate = mock(async () => ({ stackUserId: "user_1", isActive: true }));
const retrieveSession = mock(async () => ({
  id: "cs_1",
  payment_status: "paid",
  client_reference_id: "user_1",
  metadata: { app: "cmux", plan: "pro" },
  subscription: { id: "sub_1" },
  customer: { id: "cus_1" },
}));
const retrieveSubscription = mock(async () => ({
  id: "sub_1",
  customer: "cus_1",
  status: "active",
  metadata: { stackUserId: "user_1", app: "cmux" },
  cancel_at_period_end: false,
  items: { data: [{ current_period_end: 1_800_000_000, price: { id: "price_1" } }] },
}));

const POST = makeStripeWebhookHandler({
  webhookSecret: () => "whsec_test",
  isConfigured: () => true,
  stripe: () =>
    ({
      webhooks: {
        constructEvent: () => {
          if (constructThrows) throw new Error("bad signature");
          return currentEvent;
        },
      },
      checkout: {
        sessions: {
          retrieve: retrieveSession,
        },
      },
      subscriptions: {
        retrieve: retrieveSubscription,
      },
    }) as never,
  db: () =>
    ({
      insert: () => ({
        values: () => ({
          onConflictDoNothing: () => ({
            returning: () => Promise.resolve(insertedEventRows),
          }),
        }),
      }),
      select: () => ({
        from: () => ({
          where: () => ({
            limit: () => Promise.resolve(selectedEventRows),
          }),
        }),
      }),
      update: () => ({
        set: (values: Record<string, unknown>) => ({
          where: () => {
            updates.push(values);
            return Promise.resolve();
          },
        }),
      }),
    }) as never,
  recordCheckoutCompletion: recordCheckoutCompletion as never,
  applySubscriptionUpdate: applySubscriptionUpdate as never,
});

describe("Stripe billing webhook route", () => {
  beforeEach(() => {
    currentEvent = {
      id: "evt_1",
      type: "checkout.session.completed",
      data: {
        object: {
          id: "cs_1",
          client_reference_id: "user_1",
          metadata: { app: "cmux", plan: "pro" },
        },
      },
    };
    constructThrows = false;
    insertedEventRows = [{ id: "evt_1" }];
    selectedEventRows = [];
    updates.length = 0;
    recordCheckoutShouldFail = false;
    recordCheckoutCompletionResult = {
      scope: "user",
      stackUserId: "user_1",
      subscriptionId: "sub_1",
    };
    recordCheckoutCompletion.mockClear();
    applySubscriptionUpdate.mockClear();
    retrieveSession.mockClear();
    retrieveSubscription.mockClear();
  });

  test("rejects invalid Stripe signatures", async () => {
    constructThrows = true;

    const response = await POST(webhookRequest());

    expect(response.status).toBe(400);
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
  });

  test("skips duplicate events that already processed successfully", async () => {
    insertedEventRows = [];
    selectedEventRows = [{ processedAt: new Date(), error: null }];

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({ skipped: "duplicate" });
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
  });

  test("skips foreign checkout sessions", async () => {
    currentEvent = {
      id: "evt_1",
      type: "checkout.session.completed",
      data: { object: { id: "cs_foreign", metadata: { app: "other" } } },
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({ skipped: "foreign_checkout" });
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
  });

  test("records cmux checkout completions", async () => {
    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(retrieveSession).toHaveBeenCalledWith("cs_1", {
      expand: ["subscription", "customer"],
    });
    expect(recordCheckoutCompletion).toHaveBeenCalled();
    expect(updates.at(-1)).toMatchObject({ error: null });
  });

  test("reports checkout completions skipped during account deletion", async () => {
    recordCheckoutCompletionResult = {
      skipped: "account_deletion_in_progress",
      stackUserId: "user_1",
      subscriptionId: "sub_1",
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      skipped: "account_deletion_in_progress",
    });
    expect(updates.at(-1)).toMatchObject({ error: null });
  });

  test("applies deleted subscription updates", async () => {
    currentEvent = {
      id: "evt_1",
      type: "customer.subscription.deleted",
      data: {
        object: {
          id: "sub_1",
          customer: "cus_1",
          status: "canceled",
          metadata: { stackUserId: "user_1", app: "cmux" },
        },
      },
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(applySubscriptionUpdate).toHaveBeenCalledWith(
      (currentEvent.data as { object: unknown }).object,
    );
  });

  test("marks the event and returns 500 when processing fails", async () => {
    recordCheckoutShouldFail = true;

    const response = await POST(webhookRequest());

    expect(response.status).toBe(500);
    expect(updates.at(-1)).toMatchObject({ error: "db down" });
  });
});

function webhookRequest(): Request {
  return new Request("https://cmux.test/api/stripe/webhook", {
    method: "POST",
    headers: { "stripe-signature": "t=1,v1=test" },
    body: JSON.stringify({ id: "evt_1" }),
  });
}
