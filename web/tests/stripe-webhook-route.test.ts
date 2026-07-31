import { beforeEach, describe, expect, mock, test } from "bun:test";

import { makeStripeWebhookHandler } from "../app/api/stripe/webhook/route";

let currentEvent: Record<string, unknown>;
let constructThrows = false;
let insertedEventRows: unknown[] = [{ id: "evt_1" }];
let selectedEventRows: unknown[] = [];
const updates: Record<string, unknown>[] = [];
let recordCheckoutShouldFail = false;
let proWelcomeShouldFail = false;
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
const sendProSignupWelcome = mock(async () => {
  if (proWelcomeShouldFail) throw new Error("email provider unavailable");
});
const paidCheckoutSession = {
  id: "cs_1",
  payment_status: "paid",
  client_reference_id: "user_1",
  metadata: { app: "cmux", plan: "pro" },
  subscription: { id: "sub_1" },
  customer: { id: "cus_1" },
};
let retrievedCheckoutSession: Record<string, unknown> = paidCheckoutSession;
const retrieveSession = mock(async () => retrievedCheckoutSession);
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
  sendProSignupWelcome,
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
    proWelcomeShouldFail = false;
    recordCheckoutCompletionResult = {
      scope: "user",
      stackUserId: "user_1",
      subscriptionId: "sub_1",
    };
    retrievedCheckoutSession = paidCheckoutSession;
    recordCheckoutCompletion.mockClear();
    applySubscriptionUpdate.mockClear();
    sendProSignupWelcome.mockClear();
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

  test("sends the Pro signup welcome after a personal Pro checkout", async () => {
    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(sendProSignupWelcome).toHaveBeenCalledTimes(1);
    expect(sendProSignupWelcome).toHaveBeenCalledWith({
      session: expect.objectContaining({ id: "cs_1" }),
      stackUserId: "user_1",
    });
  });

  test("retries a Pro welcome when the first webhook delivery records an email error", async () => {
    proWelcomeShouldFail = true;

    const failed = await POST(webhookRequest());

    expect(failed.status).toBe(500);
    expect(updates.at(-1)).toMatchObject({ error: "email provider unavailable" });
    expect(sendProSignupWelcome).toHaveBeenCalledTimes(1);

    insertedEventRows = [];
    selectedEventRows = [{ processedAt: null, error: "email provider unavailable" }];
    proWelcomeShouldFail = false;

    const retried = await POST(webhookRequest());

    expect(retried.status).toBe(200);
    expect(sendProSignupWelcome).toHaveBeenCalledTimes(2);
    expect(updates.at(-1)).toMatchObject({ error: null });
  });

  test("defers recording and Pro email while checkout payment is pending", async () => {
    retrievedCheckoutSession = {
      ...paidCheckoutSession,
      payment_status: "unpaid",
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      skipped: "checkout_payment_pending",
    });
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
    expect(sendProSignupWelcome).not.toHaveBeenCalled();
  });

  test("records and emails a delayed Pro checkout after payment succeeds", async () => {
    currentEvent = {
      id: "evt_async_paid",
      type: "checkout.session.async_payment_succeeded",
      data: {
        object: {
          id: "cs_1",
          client_reference_id: "user_1",
          metadata: { app: "cmux", plan: "pro" },
        },
      },
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      processed: "checkout.session.async_payment_succeeded",
    });
    expect(recordCheckoutCompletion).toHaveBeenCalledTimes(1);
    expect(sendProSignupWelcome).toHaveBeenCalledTimes(1);
  });

  test("does not run personal Pro fulfillment for a team checkout", async () => {
    recordCheckoutCompletionResult = {
      scope: "team",
      stackTeamId: "team_1",
      subscriptionId: "sub_1",
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(sendProSignupWelcome).not.toHaveBeenCalled();
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
