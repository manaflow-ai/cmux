import { beforeEach, describe, expect, mock, test } from "bun:test";

import { makeStripeWebhookHandler } from "../app/api/stripe/webhook/route";
import { STRIPE_WEBHOOK_EVENT_TYPES } from "../services/billing/stripeWebhook";
import { AccountDeletionUserMutationInProgressError } from "../services/account/deletionLock";

let currentEvent: Record<string, unknown>;
let constructThrows = false;
let insertedEventRows: unknown[] = [{ id: "evt_1" }];
let selectedEventRows: unknown[] = [];
const updates: Record<string, unknown>[] = [];
let recordCheckoutShouldFail = false;
let proWelcomeShouldFail = false;
let personalWelcomeConfigured = true;
let recordCheckoutCompletionResult: unknown = {
  scope: "user",
  stackUserId: "user_1",
  subscriptionId: "sub_1",
};
const recordCheckoutCompletion = mock(async () => {
  if (recordCheckoutShouldFail) throw new Error("db down");
  return recordCheckoutCompletionResult;
});
const recordFoundersCheckoutCompletionResult: unknown = {
  scope: "user",
  stackUserId: "founder_1",
  subscriptionId: "sub_founder",
};
const recordFoundersCheckoutCompletion = mock(async () =>
  recordFoundersCheckoutCompletionResult,
);
let applySubscriptionUpdateResult: unknown = {
  scope: "user",
  stackUserId: "user_1",
  isActive: true,
};
let applySubscriptionUpdateError: Error | null = null;
const applySubscriptionUpdate = mock(async () => {
  if (applySubscriptionUpdateError) throw applySubscriptionUpdateError;
  return applySubscriptionUpdateResult;
});
const markTeamSeatsDirty = mock(async () => {});
const revokeCoderouterRouteTokens = mock(async () => {});
const revokeCoderouterTeamRouteTokens = mock(async () => {});
const captureStripeBillingEvent = mock(async () => {});
const deferredTasks: Array<() => Promise<void>> = [];
const sendProSignupWelcome = mock(async () => {
  if (proWelcomeShouldFail) throw new Error("email provider unavailable");
});
const paidCheckoutSession = {
  id: "cs_1",
  payment_status: "paid",
  client_reference_id: "user_1",
  metadata: { app: "cmux", plan: "pro" },
  subscription: { id: "sub_1", status: "active" },
  customer: { id: "cus_1" },
};
let retrievedCheckoutSession: Record<string, unknown> = paidCheckoutSession;
const retrieveSession = mock(async () => retrievedCheckoutSession);
let retrievedSubscription: Record<string, unknown> = {
  id: "sub_1",
  customer: "cus_1",
  status: "active",
  metadata: { stackUserId: "user_1", app: "cmux" },
  cancel_at_period_end: false,
  items: { data: [{ current_period_end: 1_800_000_000, price: { id: "price_1" } }] },
};
const retrieveSubscription = mock(async () => retrievedSubscription);
let retrievedInvoice: Record<string, unknown> = {
  id: "in_1",
  subscription: "sub_1",
};
const retrieveInvoice = mock(async () => retrievedInvoice);

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
      invoices: {
        retrieve: retrieveInvoice,
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
  recordFoundersCheckoutCompletion: recordFoundersCheckoutCompletion as never,
  applySubscriptionUpdate: applySubscriptionUpdate as never,
  markTeamSeatsDirty,
  sendProSignupWelcome,
  isPersonalWelcomeConfigured: () => personalWelcomeConfigured,
  revokeCoderouterRouteTokens,
  revokeCoderouterTeamRouteTokens,
  captureStripeBillingEvent,
  defer: (task) => deferredTasks.push(task),
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
    applySubscriptionUpdateError = null;
    proWelcomeShouldFail = false;
    personalWelcomeConfigured = true;
    recordCheckoutCompletionResult = {
      scope: "user",
      stackUserId: "user_1",
      subscriptionId: "sub_1",
    };
    applySubscriptionUpdateResult = {
      scope: "user",
      stackUserId: "user_1",
      isActive: true,
    };
    retrievedCheckoutSession = paidCheckoutSession;
    retrievedSubscription = {
      id: "sub_1",
      customer: "cus_1",
      status: "active",
      metadata: { stackUserId: "user_1", app: "cmux" },
      cancel_at_period_end: false,
      items: {
        data: [{
          current_period_end: 1_800_000_000,
          price: { id: "price_1" },
        }],
      },
    };
    retrievedInvoice = { id: "in_1", subscription: "sub_1" };
    recordCheckoutCompletion.mockClear();
    recordFoundersCheckoutCompletion.mockClear();
    applySubscriptionUpdate.mockClear();
    markTeamSeatsDirty.mockClear();
    revokeCoderouterRouteTokens.mockClear();
    revokeCoderouterTeamRouteTokens.mockClear();
    captureStripeBillingEvent.mockClear();
    deferredTasks.length = 0;
    sendProSignupWelcome.mockClear();
    retrieveSession.mockClear();
    retrieveSubscription.mockClear();
    retrieveInvoice.mockClear();
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

  test("uses the retrieved session marker when the event payload omits metadata", async () => {
    currentEvent = {
      id: "evt_retrieved_foreign",
      type: "checkout.session.completed",
      data: { object: { id: "cs_retrieved_foreign", metadata: {} } },
    };
    retrievedCheckoutSession = {
      ...paidCheckoutSession,
      id: "cs_retrieved_foreign",
      metadata: { app: "other", plan: "pro" },
      subscription: {
        id: "sub_retrieved_foreign",
        status: "active",
        metadata: { app: "cmux", plan: "pro" },
      },
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
    expect(captureStripeBillingEvent).not.toHaveBeenCalled();
    expect(deferredTasks).toHaveLength(1);
    await deferredTasks[0]();
    expect(captureStripeBillingEvent).toHaveBeenCalledWith(
      currentEvent,
      {
        scope: "user",
        stackUserId: "user_1",
        isActive: true,
        status: "active",
      },
    );
    expect(updates.at(-1)).toMatchObject({ error: null });
  });

  test("routes Founder's Edition sessions through the dedicated recorder", async () => {
    retrievedCheckoutSession = {
      ...paidCheckoutSession,
      id: "cs_founder",
      client_reference_id: null,
      metadata: { founders_edition: "true" },
      subscription: { id: "sub_founder", status: "active" },
      customer: { id: "cus_founder" },
    };
    currentEvent = {
      id: "evt_founder",
      type: "checkout.session.completed",
      data: {
        object: {
          id: "cs_founder",
          metadata: { founders_edition: "true" },
        },
      },
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(recordFoundersCheckoutCompletion).toHaveBeenCalledTimes(1);
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
    expect(sendProSignupWelcome).not.toHaveBeenCalled();
  });

  test("routes a Founder checkout when the marker exists only on the subscription", async () => {
    retrievedCheckoutSession = {
      ...paidCheckoutSession,
      id: "cs_founder_subscription_metadata",
      client_reference_id: null,
      metadata: {},
      subscription: {
        id: "sub_founder_subscription_metadata",
        status: "active",
        metadata: { founders_edition: "true" },
      },
      customer: { id: "cus_founder_subscription_metadata" },
    };
    currentEvent = {
      id: "evt_founder_subscription_metadata",
      type: "checkout.session.completed",
      data: {
        object: {
          id: "cs_founder_subscription_metadata",
          client_reference_id: null,
          metadata: {},
        },
      },
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(recordFoundersCheckoutCompletion).toHaveBeenCalledTimes(1);
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
  });

  test("skips conflicting Team and Founder checkout metadata", async () => {
    retrievedCheckoutSession = {
      ...paidCheckoutSession,
      id: "cs_conflicting_scope",
      client_reference_id: "team_1",
      metadata: {
        founders_edition: "true",
        app: "cmux",
        plan: "team",
        stackTeamId: "team_1",
      },
      subscription: {
        id: "sub_conflicting_scope",
        status: "active",
        metadata: {
          founders_edition: "true",
          app: "cmux",
          plan: "team",
          stackTeamId: "team_1",
        },
      },
    };
    currentEvent = {
      id: "evt_conflicting_scope",
      type: "checkout.session.completed",
      data: {
        object: {
          id: "cs_conflicting_scope",
          metadata: {
            founders_edition: "true",
            app: "cmux",
            plan: "team",
            stackTeamId: "team_1",
          },
        },
      },
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      skipped: "conflicting_checkout_metadata",
    });
    expect(recordFoundersCheckoutCompletion).not.toHaveBeenCalled();
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
  });

  test("skips conflicting Pro and Founder checkout metadata", async () => {
    retrievedCheckoutSession = {
      ...paidCheckoutSession,
      id: "cs_conflicting_pro",
      metadata: {
        founders_edition: "true",
        app: "cmux",
        plan: "pro",
      },
      subscription: {
        id: "sub_conflicting_pro",
        status: "active",
        metadata: {
          founders_edition: "true",
          app: "cmux",
          plan: "pro",
        },
      },
    };
    currentEvent = {
      id: "evt_conflicting_pro",
      type: "checkout.session.completed",
      data: {
        object: {
          id: "cs_conflicting_pro",
          metadata: {
            founders_edition: "true",
            app: "cmux",
            plan: "pro",
          },
        },
      },
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      skipped: "conflicting_checkout_metadata",
    });
    expect(recordFoundersCheckoutCompletion).not.toHaveBeenCalled();
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
  });

  test("skips a stale Founder event when the retrieved checkout is Pro", async () => {
    retrievedCheckoutSession = {
      ...paidCheckoutSession,
      id: "cs_stale_founder_event",
      metadata: { app: "cmux", plan: "pro" },
      subscription: {
        id: "sub_stale_founder_event",
        status: "active",
        metadata: { app: "cmux", plan: "pro" },
      },
    };
    currentEvent = {
      id: "evt_stale_founder_event",
      type: "checkout.session.completed",
      data: {
        object: {
          id: "cs_stale_founder_event",
          metadata: { founders_edition: "true" },
        },
      },
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      skipped: "conflicting_checkout_metadata",
    });
    expect(recordFoundersCheckoutCompletion).not.toHaveBeenCalled();
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
  });

  test("leaves the Pro personal welcome to the founders-welcome endpoint", async () => {
    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(sendProSignupWelcome).not.toHaveBeenCalled();
  });

  test("does not use the legacy templated Pro sender on retries", async () => {
    proWelcomeShouldFail = true;
    const response = await POST(webhookRequest());
    expect(response.status).toBe(200);
    expect(sendProSignupWelcome).not.toHaveBeenCalled();
  });

  test("keeps the legacy Pro sender only when the personal endpoint is unavailable", async () => {
    personalWelcomeConfigured = false;

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(sendProSignupWelcome).toHaveBeenCalledTimes(1);
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

  test("does not mark a settled checkout active when its subscription is incomplete", async () => {
    retrievedCheckoutSession = {
      ...paidCheckoutSession,
      subscription: { id: "sub_1", status: "incomplete" },
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    await deferredTasks[0]();
    expect(captureStripeBillingEvent).toHaveBeenCalledWith(
      currentEvent,
      expect.objectContaining({
        isActive: false,
        status: "incomplete",
      }),
    );
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
    expect(sendProSignupWelcome).not.toHaveBeenCalled();
  });

  test("records a fully discounted checkout that requires no payment", async () => {
    retrievedCheckoutSession = {
      ...paidCheckoutSession,
      payment_status: "no_payment_required",
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(recordCheckoutCompletion).toHaveBeenCalledTimes(1);
    expect(sendProSignupWelcome).not.toHaveBeenCalled();
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
    applySubscriptionUpdateResult = {
      scope: "user",
      stackUserId: "user_1",
      isActive: false,
    };
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
    retrievedSubscription = {
      ...(currentEvent.data as { object: Record<string, unknown> }).object,
      cancel_at_period_end: false,
      items: { data: [] },
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(applySubscriptionUpdate).toHaveBeenCalledWith(
      retrievedSubscription,
      { markTeamSeatsDirty: false },
    );
    expect(revokeCoderouterRouteTokens).toHaveBeenCalledWith("user_1");
    expect(captureStripeBillingEvent).not.toHaveBeenCalled();
    expect(deferredTasks).toHaveLength(1);
    await deferredTasks[0]();
    expect(captureStripeBillingEvent).toHaveBeenCalledWith(
      currentEvent,
      {
        scope: "user",
        stackUserId: "user_1",
        isActive: false,
        status: "canceled",
      },
    );
  });

  test("revokes every selected-team route after Team cancellation", async () => {
    applySubscriptionUpdateResult = {
      scope: "team",
      stackTeamId: "team_1",
      isActive: false,
    };
    currentEvent = {
      id: "evt_team_deleted",
      type: "customer.subscription.deleted",
      data: {
        object: {
          id: "sub_team",
          customer: "cus_team",
          status: "canceled",
          metadata: { stackTeamId: "team_1", app: "cmux", plan: "team" },
        },
      },
    };
    retrievedSubscription = {
      ...(currentEvent.data as { object: Record<string, unknown> }).object,
      cancel_at_period_end: false,
      items: { data: [] },
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(revokeCoderouterTeamRouteTokens).toHaveBeenCalledWith("team_1");
    expect(revokeCoderouterRouteTokens).not.toHaveBeenCalled();
  });

  test("repairs delayed subscription events from Stripe's current state", async () => {
    currentEvent = {
      id: "evt_stale_deleted",
      type: "customer.subscription.deleted",
      data: {
        object: {
          id: "sub_1",
          status: "canceled",
          metadata: { stackUserId: "user_1", app: "cmux" },
        },
      },
    };
    retrievedSubscription = {
      id: "sub_1",
      customer: "cus_1",
      status: "active",
      metadata: { stackUserId: "user_1", app: "cmux" },
      cancel_at_period_end: false,
      items: { data: [] },
    };
    applySubscriptionUpdateResult = {
      scope: "user",
      stackUserId: "user_1",
      isActive: true,
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(retrieveSubscription).toHaveBeenCalledWith("sub_1");
    expect(applySubscriptionUpdate).toHaveBeenCalledWith(retrievedSubscription, { markTeamSeatsDirty: false });
    expect(revokeCoderouterRouteTokens).not.toHaveBeenCalled();
    await deferredTasks[0]();
    expect(captureStripeBillingEvent).toHaveBeenCalledWith(currentEvent, {
      scope: "user",
      stackUserId: "user_1",
      isActive: true,
      status: "active",
    });
  });

  test("revokes coderouter tokens for an inactive invoice subscription update", async () => {
    currentEvent = {
      id: "evt_invoice_failed",
      type: "invoice.payment_failed",
      data: {
        object: {
          id: "in_1",
          subscription: "sub_1",
        },
      },
    };
    applySubscriptionUpdateResult = {
      scope: "user",
      stackUserId: "user_1",
      isActive: false,
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(retrieveSubscription).toHaveBeenCalledWith("sub_1");
    expect(revokeCoderouterRouteTokens).toHaveBeenCalledWith("user_1");
  });

  test("restores entitlement without revoking tokens after invoice recovery", async () => {
    currentEvent = {
      id: "evt_invoice_paid",
      type: "invoice.paid",
      data: {
        object: {
          id: "in_1",
          subscription: "sub_1",
        },
      },
    };
    applySubscriptionUpdateResult = {
      scope: "user",
      stackUserId: "user_1",
      isActive: true,
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(retrieveSubscription).toHaveBeenCalledWith("sub_1");
    expect(applySubscriptionUpdate).toHaveBeenCalledTimes(1);
    expect(revokeCoderouterRouteTokens).not.toHaveBeenCalled();
  });

  test("does not revoke tokens when an invoice subscription is unmapped", async () => {
    currentEvent = {
      id: "evt_invoice_unmapped",
      type: "invoice.payment_failed",
      data: {
        object: {
          id: "in_1",
          subscription: "sub_foreign",
        },
      },
    };
    applySubscriptionUpdateResult = { skipped: "subscription_unmapped" };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      skipped: "invoice_subscription_unmapped",
    });
    expect(revokeCoderouterRouteTokens).not.toHaveBeenCalled();
  });

  test("records refunds without revoking an otherwise active subscription", async () => {
    currentEvent = {
      id: "evt_refunded",
      type: "charge.refunded",
      data: {
        object: {
          id: "ch_1",
          invoice: "in_1",
          amount: 3000,
          amount_refunded: 3000,
          currency: "usd",
          refunded: true,
        },
      },
    };
    applySubscriptionUpdateResult = {
      scope: "user",
      stackUserId: "user_1",
      isActive: true,
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(retrieveInvoice).toHaveBeenCalledWith("in_1");
    expect(retrieveSubscription).toHaveBeenCalledWith("sub_1");
    expect(revokeCoderouterRouteTokens).not.toHaveBeenCalled();
    await deferredTasks[0]();
    expect(captureStripeBillingEvent).toHaveBeenCalledWith(currentEvent, {
      scope: "user",
      stackUserId: "user_1",
      isActive: true,
      status: "active",
    });
  });

  test("marks the event and returns 500 when processing fails", async () => {
    recordCheckoutShouldFail = true;

    const response = await POST(webhookRequest());

    expect(response.status).toBe(500);
    expect(updates.at(-1)).toMatchObject({ error: "db down" });
  });

  test("defers a subscription event that lost the account mutation lease to a sibling event", async () => {
    // Stripe delivers customer.subscription.created, invoice.paid, and
    // checkout.session.completed for one purchase within a second. The losers
    // of the per-account lease must be retried, not reported as failures.
    currentEvent = {
      id: "evt_1",
      type: "customer.subscription.created",
      data: { object: { id: "sub_1" } },
    };
    applySubscriptionUpdateError = new AccountDeletionUserMutationInProgressError("user_1");

    const response = await POST(webhookRequest());

    expect(response.status).toBe(503);
    expect(updates.at(-1)).toMatchObject({
      error: "retryable: Another account mutation is still in progress.",
    });
  });

  test("queues Team seat reconciliation for subscription create and update events", async () => {
    for (const type of ["customer.subscription.created", "customer.subscription.updated"]) {
      applySubscriptionUpdate.mockClear();
      currentEvent = {
        id: `evt_${type}`,
        type,
        data: { object: { id: "sub_team" } },
      };
      retrievedSubscription = {
        id: "sub_team",
        customer: "cus_team",
        status: "active",
        metadata: { stackTeamId: "team_1", app: "cmux", plan: "team" },
        cancel_at_period_end: false,
        items: { data: [{ quantity: 2, price: { id: "price_team" } }] },
      };
      applySubscriptionUpdateResult = { scope: "team", stackTeamId: "team_1", isActive: true };

      expect((await POST(webhookRequest())).status).toBe(200);
      expect(applySubscriptionUpdate).toHaveBeenCalledWith(retrievedSubscription, { markTeamSeatsDirty });
    }
  });

  test("queues Team seat reconciliation when a pending quantity update applies", async () => {
    currentEvent = {
      id: "evt_pending_applied",
      type: "customer.subscription.pending_update_applied",
      data: { object: { id: "sub_team" } },
    };
    applySubscriptionUpdateResult = { scope: "team", stackTeamId: "team_1", isActive: true };

    expect((await POST(webhookRequest())).status).toBe(200);
    expect(applySubscriptionUpdate).toHaveBeenCalledWith(retrievedSubscription, { markTeamSeatsDirty });
  });

  test("does not queue seat reconciliation for lifecycle events that keep the quantity", async () => {
    for (const type of ["customer.subscription.paused", "customer.subscription.resumed", "invoice.paid"]) {
      applySubscriptionUpdate.mockClear();
      currentEvent = {
        id: `evt_${type}`,
        type,
        data: { object: { id: "sub_1", subscription: "sub_1" } },
      };

      expect((await POST(webhookRequest())).status).toBe(200);
      expect(applySubscriptionUpdate).toHaveBeenCalledWith(retrievedSubscription, { markTeamSeatsDirty: false });
    }
  });

  test("revokes access when a subscription pauses", async () => {
    currentEvent = {
      id: "evt_paused",
      type: "customer.subscription.paused",
      data: { object: { id: "sub_1", status: "paused" } },
    };
    retrievedSubscription = { ...retrievedSubscription, status: "paused" };
    applySubscriptionUpdateResult = { scope: "user", stackUserId: "user_1", isActive: false };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ processed: "customer.subscription.paused" });
    expect(retrieveSubscription).toHaveBeenCalledWith("sub_1");
    expect(revokeCoderouterRouteTokens).toHaveBeenCalledWith("user_1");
  });

  test("restores access from Stripe's current state when a subscription resumes", async () => {
    currentEvent = {
      id: "evt_resumed",
      type: "customer.subscription.resumed",
      data: { object: { id: "sub_1", status: "active" } },
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(applySubscriptionUpdate).toHaveBeenCalledTimes(1);
    expect(revokeCoderouterRouteTokens).not.toHaveBeenCalled();
  });

  test("applies the subscription state when an invoice needs customer action", async () => {
    for (const type of ["invoice.payment_action_required", "invoice.marked_uncollectible"]) {
      retrieveSubscription.mockClear();
      revokeCoderouterRouteTokens.mockClear();
      currentEvent = {
        id: `evt_${type}`,
        type,
        data: { object: { id: "in_1", parent: { subscription_details: { subscription: "sub_1" } } } },
      };
      applySubscriptionUpdateResult = { scope: "user", stackUserId: "user_1", isActive: false };

      const response = await POST(webhookRequest());

      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({ processed: type });
      expect(retrieveSubscription).toHaveBeenCalledWith("sub_1");
      expect(revokeCoderouterRouteTokens).toHaveBeenCalledWith("user_1");
    }
  });

  test("applies the subscription's state when a delayed checkout payment fails", async () => {
    currentEvent = {
      id: "evt_async_failed",
      type: "checkout.session.async_payment_failed",
      data: {
        object: {
          id: "cs_1",
          payment_status: "unpaid",
          metadata: { app: "cmux", plan: "pro" },
          subscription: "sub_1",
        },
      },
    };
    retrievedSubscription = { ...retrievedSubscription, status: "incomplete_expired" };
    applySubscriptionUpdateResult = { scope: "user", stackUserId: "user_1", isActive: false };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ processed: "checkout.session.async_payment_failed" });
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
    expect(sendProSignupWelcome).not.toHaveBeenCalled();
    expect(retrieveSubscription).toHaveBeenCalledWith("sub_1");
    expect(revokeCoderouterRouteTokens).toHaveBeenCalledWith("user_1");
  });

  test("skips a failed delayed payment for a checkout without a subscription", async () => {
    currentEvent = {
      id: "evt_async_failed_payment",
      type: "checkout.session.async_payment_failed",
      data: {
        object: {
          id: "cs_founder",
          payment_status: "unpaid",
          metadata: { founders_edition: "true" },
          subscription: null,
        },
      },
    };

    const response = await POST(webhookRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ skipped: "checkout_without_subscription" });
    expect(recordFoundersCheckoutCompletion).not.toHaveBeenCalled();
    expect(applySubscriptionUpdate).not.toHaveBeenCalled();
  });

  test("acts on every event type the endpoint subscribes to", async () => {
    for (const type of STRIPE_WEBHOOK_EVENT_TYPES) {
      currentEvent = {
        id: `evt_${type}`,
        type,
        data: {
          object: {
            id: type.startsWith("charge.") ? "ch_1" : type.startsWith("invoice.") ? "in_1" : "obj_1",
            metadata: { app: "cmux", plan: "pro" },
            subscription: "sub_1",
            invoice: "in_1",
          },
        },
      };

      const response = await POST(webhookRequest());

      expect(await response.json()).not.toMatchObject({ skipped: "event_type" });
    }
  });
});

function webhookRequest(origin = "https://cmux.test"): Request {
  return new Request(`${origin}/api/stripe/webhook`, {
    method: "POST",
    headers: { "stripe-signature": "t=1,v1=test" },
    body: JSON.stringify({ id: "evt_1" }),
  });
}
