import { describe, expect, test } from "bun:test";
import type Stripe from "stripe";

import { captureStripeBillingEvent } from "../services/analytics/stripeBilling";

describe("Stripe billing analytics", () => {
  test("joins paid checkout events to the Stack PostHog identity", async () => {
    let capturedInit: RequestInit | undefined;
    const postHogFetch = (async (_input: string | URL | Request, init?: RequestInit) => {
      capturedInit = init;
      return new Response(null, { status: 200 });
    }) as typeof fetch;
    const event = {
      id: "evt_checkout",
      type: "checkout.session.completed",
      data: {
        object: {
          id: "cs_1",
          amount_total: 3000,
          currency: "usd",
          payment_status: "paid",
          customer: "cus_1",
          subscription: "sub_1",
          metadata: {
            plan: "pro",
            billingInterval: "month",
          },
        },
      },
    } as unknown as Stripe.Event;

    await captureStripeBillingEvent(
      event,
      {
        scope: "user",
        stackUserId: "stack-user-1",
        isActive: true,
        status: "active",
      },
      postHogFetch,
    );

    const payload = JSON.parse(String(capturedInit?.body));
    expect(payload.event).toBe("cmux_billing_checkout_completed");
    expect(payload.properties).toMatchObject({
      distinct_id: "stack-user-1",
      $insert_id: "evt_checkout",
      stack_user_id: "stack-user-1",
      plan: "pro",
      billing_interval: "month",
      amount_total: 3000,
      is_active: true,
      billing_status: "active",
      stripe_customer_id: "cus_1",
    });
  });

  test("maps subscription cancellation into immutable event properties", async () => {
    let capturedInit: RequestInit | undefined;
    const postHogFetch = (async (_input: string | URL | Request, init?: RequestInit) => {
      capturedInit = init;
      return new Response(null, { status: 200 });
    }) as typeof fetch;
    const event = {
      id: "evt_deleted",
      type: "customer.subscription.deleted",
      data: {
        object: {
          id: "sub_1",
          customer: "cus_1",
          status: "canceled",
          cancel_at_period_end: false,
          metadata: { plan: "pro", billingInterval: "year" },
        },
      },
    } as unknown as Stripe.Event;

    await captureStripeBillingEvent(
      event,
      {
        scope: "user",
        stackUserId: "stack-user-1",
        isActive: false,
        status: "canceled",
      },
      postHogFetch,
    );

    const payload = JSON.parse(String(capturedInit?.body));
    expect(payload.event).toBe("cmux_billing_subscription_deleted");
    expect(payload.properties).toMatchObject({
      is_active: false,
      billing_status: "canceled",
      stripe_customer_id: "cus_1",
    });
    expect(payload.properties.$set).toBeUndefined();
  });

  test("does not make billing fail when PostHog is unavailable", async () => {
    const postHogFetch = (async () => {
      throw new Error("offline");
    }) as typeof fetch;
    const event = {
      id: "evt_failed",
      type: "invoice.payment_failed",
      data: {
        object: {
          id: "in_1",
          amount_due: 3000,
          amount_paid: 0,
          currency: "usd",
          customer: "cus_1",
        },
      },
    } as unknown as Stripe.Event;

    await expect(captureStripeBillingEvent(
      event,
      { scope: "user", stackUserId: "stack-user-1", isActive: false },
      postHogFetch,
    )).resolves.toBeUndefined();
  });
});
