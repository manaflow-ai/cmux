import { describe, expect, test } from "bun:test";
import type Stripe from "stripe";

import {
  captureBillingCheckoutStarted,
  captureStripeBillingEvent,
} from "../services/analytics/stripeBilling";
import {
  checkoutAttributionFromRequest,
} from "../services/analytics/checkoutAttribution";

const WEB_ATTRIBUTION = checkoutAttributionFromRequest({
  searchParams: new URLSearchParams("cmux_source=pricing_page&cmux_placement=hero"),
  referer: "https://cmux.com/pricing?interval=year",
});

describe("Stripe billing analytics", () => {
  test("does not use the real transport in a test process", async () => {
    const originalFetch = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = (async () => {
      calls += 1;
      return new Response(null, { status: 200 });
    }) as typeof fetch;
    try {
      await captureBillingCheckoutStarted({
        sessionId: "cs_test_guard",
        subject: { scope: "user", stackUserId: "stack-user-test" },
        plan: "pro",
        billingInterval: "month",
        attribution: WEB_ATTRIBUTION,
        signedIn: false,
        existingStripeCustomer: false,
      });
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(calls).toBe(0);
  });

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
    let attempts = 0;
    const postHogFetch = (async () => {
      attempts += 1;
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
    expect(attempts).toBe(2);
  });

  test("captures checkout start with a stable deduplication id and no email", async () => {
    let payload: Record<string, unknown> = {};
    await captureBillingCheckoutStarted({
      sessionId: "cs_started",
      subject: { scope: "user", stackUserId: "stack-user-1" },
      plan: "pro",
      billingInterval: "year",
      attribution: WEB_ATTRIBUTION,
      signedIn: true,
      existingStripeCustomer: false,
    }, (async (_input, init) => {
      payload = JSON.parse(String(init?.body));
      return new Response(null, { status: 200 });
    }) as typeof fetch);

    expect(payload).toMatchObject({
      event: "cmux_billing_checkout_started",
      properties: {
        distinct_id: "stack-user-1",
        $insert_id: "checkout-started:cs_started",
        plan: "pro",
        billing_interval: "year",
        signed_in: true,
        existing_stripe_customer: false,
        checkout_source: "pricing_page",
        checkout_placement: "hero",
        checkout_client: "web",
        checkout_channel: null,
        checkout_referrer_host: "cmux.com",
        checkout_referrer_path: "/pricing",
      },
    });
    expect(JSON.stringify(payload)).not.toContain("email");
  });

  test("carries app attribution from Stripe metadata onto paid events", async () => {
    let payload: Record<string, unknown> = {};
    const event = {
      id: "evt_checkout_mac",
      type: "checkout.session.completed",
      created: 1_800_000_600,
      data: {
        object: {
          id: "cs_mac",
          created: 1_800_000_000,
          amount_total: 5000,
          currency: "usd",
          payment_status: "paid",
          payment_method_types: ["card", "link"],
          customer: "cus_mac",
          subscription: "sub_mac",
          customer_details: { address: { country: "US" } },
          total_details: { amount_discount: 500 },
          metadata: {
            plan: "pro",
            billingInterval: "year",
            cmuxSource: "mac_sidebar_badge",
            cmuxClient: "mac",
            cmuxChannel: "nightly",
            cmuxAppVersion: "0.65.1",
            cmuxAppBuild: "2026090101",
          },
        },
      },
    } as unknown as Stripe.Event;

    await captureStripeBillingEvent(
      event,
      { scope: "user", stackUserId: "stack-user-mac", isActive: true, status: "active" },
      (async (_input, init) => {
        payload = JSON.parse(String(init?.body));
        return new Response(null, { status: 200 });
      }) as typeof fetch,
    );

    expect(payload).toMatchObject({
      event: "cmux_billing_checkout_completed",
      properties: {
        checkout_source: "mac_sidebar_badge",
        checkout_client: "mac",
        checkout_channel: "nightly",
        checkout_app_version: "0.65.1",
        checkout_app_build: "2026090101",
        checkout_placement: null,
        payment_method_types: ["card", "link"],
        customer_country: "US",
        amount_discount: 500,
        promotion_applied: true,
        checkout_duration_seconds: 600,
        $set: { billing_plan: "pro", billing_customer_type: "user" },
        $set_once: {
          first_paid_checkout_source: "mac_sidebar_badge",
          first_paid_checkout_client: "mac",
          first_paid_checkout_channel: "nightly",
          first_paid_checkout_at: new Date(1_800_000_600 * 1000).toISOString(),
        },
      },
    });
  });

  test("reads pre-attribution sessions as unknown web checkouts", async () => {
    let payload: Record<string, unknown> = {};
    const event = {
      id: "evt_expired",
      type: "checkout.session.expired",
      created: 1_800_000_600,
      data: {
        object: {
          id: "cs_old",
          amount_total: 5000,
          currency: "usd",
          customer: null,
          metadata: { plan: "pro", billingInterval: "month", app: "cmux" },
        },
      },
    } as unknown as Stripe.Event;

    await captureStripeBillingEvent(
      event,
      { scope: "user", stackUserId: "stack-user-old", isActive: false, status: "expired" },
      (async (_input, init) => {
        payload = JSON.parse(String(init?.body));
        return new Response(null, { status: 200 });
      }) as typeof fetch,
    );

    expect(payload).toMatchObject({
      event: "cmux_billing_checkout_expired",
      properties: {
        distinct_id: "stack-user-old",
        checkout_source: "unknown",
        checkout_client: "web",
        checkout_channel: null,
        stripe_checkout_session_id: "cs_old",
      },
    });
  });

  test("captures refunds without payment method details", async () => {
    let payload: Record<string, unknown> = {};
    await captureStripeBillingEvent({
      id: "evt_refund",
      type: "charge.refunded",
      data: {
        object: {
          id: "ch_1",
          amount: 3000,
          amount_refunded: 3000,
          currency: "usd",
          refunded: true,
          customer: "cus_1",
        },
      },
    } as unknown as Stripe.Event, {
      scope: "user",
      stackUserId: "stack-user-1",
      isActive: false,
      status: "canceled",
    }, (async (_input, init) => {
      payload = JSON.parse(String(init?.body));
      return new Response(null, { status: 200 });
    }) as typeof fetch);

    expect(payload).toMatchObject({
      event: "cmux_billing_charge_refunded",
      properties: {
        distinct_id: "stack-user-1",
        amount_refunded: 3000,
        fully_refunded: true,
      },
    });
    expect(JSON.stringify(payload)).not.toMatch(/card|payment_method|receipt_url/);
  });
});
