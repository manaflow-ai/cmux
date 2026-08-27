import { createHmac } from "node:crypto";

import {
  afterAll,
  beforeEach,
  describe,
  expect,
  mock,
  setSystemTime,
  test,
} from "bun:test";

// Route-level coverage for the purchase-time newsletter segment upsert in
// /api/stripe/founders-welcome: it runs only for Founder's Edition sessions
// whose payment actually settled, and a failure inside it never turns a
// delivered welcome email into a webhook error (which would trigger Stripe
// retries).

const WEBHOOK_SECRET = process.env.STRIPE_FOUNDERS_WEBHOOK_SECRET ?? "";

let resendError: { name: string; message: string } | null = null;
const resendSend = mock(async () => ({
  data: resendError ? null : { id: "email_1" },
  error: resendError,
}));

mock.module("resend", () => ({
  Resend: class MockResend {
    emails = { send: resendSend };
  },
}));

type UpsertCall = { email: string; customerName?: string | null };
const upsertCalls: UpsertCall[] = [];
let upsertError: Error | null = null;
let upsertResult: unknown[] = [];
const upsertFounderIntoSegments = mock(async (...args: unknown[]) => {
  const options = args[0] as UpsertCall;
  upsertCalls.push({
    email: options.email,
    customerName: options.customerName,
  });
  if (upsertError) {
    throw upsertError;
  }
  return upsertResult;
});

mock.module("@/services/newsletter/founder-hook", () => ({
  upsertFounderIntoSegments,
  // The route wraps the upsert in the real module's deadline helper; keep
  // the pass-through behavior so route tests exercise the call flow.
  withDeadline: async <T,>(work: Promise<T>) => work,
}));

const { POST } = await import("../app/api/stripe/founders-welcome/route");

const FROZEN_NOW_MS = Date.UTC(2026, 6, 24, 12, 0, 0);
const FROZEN_NOW_SECONDS = Math.floor(FROZEN_NOW_MS / 1000);

beforeEach(() => {
  setSystemTime(FROZEN_NOW_MS);
  resendSend.mockClear();
  resendError = null;
  upsertFounderIntoSegments.mockClear();
  upsertCalls.length = 0;
  upsertError = null;
  upsertResult = [];
});

afterAll(() => {
  setSystemTime();
});

function signedRequest(body: string): Request {
  const v1 = createHmac("sha256", WEBHOOK_SECRET)
    .update(`${FROZEN_NOW_SECONDS}.${body}`)
    .digest("hex");
  return new Request("https://cmux.test/api/stripe/founders-welcome", {
    method: "POST",
    headers: { "stripe-signature": `t=${FROZEN_NOW_SECONDS},v1=${v1}` },
    body,
  });
}

function checkoutCompletedEvent(
  metadata: Record<string, string>,
  overrides: {
    payment_status?: string | null;
    amount_total?: number | null;
  } = {},
): string {
  return JSON.stringify({
    id: "evt_1",
    type: "checkout.session.completed",
    data: {
      object: {
        id: "cs_test_123",
        metadata,
        payment_status: overrides.payment_status ?? "paid",
        amount_total: overrides.amount_total ?? 1000,
        customer_details: {
          email: "customer@example.com",
          name: "Ada Lovelace",
        },
      },
    },
  });
}

describe("founders welcome segment upsert", () => {
  test("upserts the buyer for a paid Founder's Edition session", async () => {
    const response = await POST(
      signedRequest(checkoutCompletedEvent({ founders_edition: "true" })),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
    expect(upsertCalls).toEqual([
      { email: "customer@example.com", customerName: "Ada Lovelace" },
    ]);
  });

  test("upserts for a no_payment_required founder session", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent(
          { founders_edition: "true" },
          { payment_status: "no_payment_required", amount_total: 0 },
        ),
      ),
    );

    expect(response.status).toBe(200);
    expect(upsertFounderIntoSegments).toHaveBeenCalledTimes(1);
  });

  test("does not upsert when the payment has not settled yet", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent(
          { founders_edition: "true" },
          { payment_status: "unpaid" },
        ),
      ),
    );

    // The welcome email itself still goes out (existing behavior); only the
    // permanent segment membership waits for a settled payment.
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
    expect(upsertFounderIntoSegments).not.toHaveBeenCalled();
  });

  test("does not upsert a non-zero no-payment session", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent(
          { founders_edition: "true" },
          { payment_status: "no_payment_required", amount_total: 1000 },
        ),
      ),
    );
    expect(response.status).toBe(200);
    expect(upsertFounderIntoSegments).not.toHaveBeenCalled();
  });

  test("does not touch segments for non-founder checkouts", async () => {
    const response = await POST(
      signedRequest(checkoutCompletedEvent({ app: "cmux", plan: "team" })),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
    expect(upsertFounderIntoSegments).not.toHaveBeenCalled();
  });

  test("a segment upsert failure never fails the webhook", async () => {
    upsertError = new Error("resend segment API down");

    const response = await POST(
      signedRequest(checkoutCompletedEvent({ founders_edition: "true" })),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
    expect(upsertFounderIntoSegments).toHaveBeenCalledTimes(1);
  });

  test("async_payment_succeeded triggers the deferred founder upsert", async () => {
    const body = JSON.stringify({
      id: "evt_async",
      type: "checkout.session.async_payment_succeeded",
      data: {
        object: {
          id: "cs_test_async",
          metadata: { founders_edition: "true" },
          payment_status: "paid",
          customer_details: {
            email: "customer@example.com",
            name: "Ada Lovelace",
          },
        },
      },
    });

    const response = await POST(signedRequest(body));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, upsert: "completed" });
    // No second welcome email: only the segment upsert runs on this event.
    expect(resendSend).not.toHaveBeenCalled();
    expect(upsertCalls).toEqual([
      { email: "customer@example.com", customerName: "Ada Lovelace" },
    ]);
  });

  test("async_payment_succeeded reports a failed upsert honestly", async () => {
    upsertError = new Error("resend down");
    const body = JSON.stringify({
      id: "evt_async",
      type: "checkout.session.async_payment_succeeded",
      data: {
        object: {
          id: "cs_test_async",
          metadata: { founders_edition: "true" },
          payment_status: "paid",
          customer_details: { email: "customer@example.com" },
        },
      },
    });

    const response = await POST(signedRequest(body));

    // Still a 200 acknowledgement (best-effort contract), but the body
    // does not claim success.
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, upsert: "failed" });
  });

  test("reports missing audience resources as a failed upsert", async () => {
    upsertResult = [
      { segmentName: "cmux Users", outcome: "skipped_missing_segment" },
      { segmentName: "cmux Founder's Edition", outcome: "created" },
    ];
    const body = JSON.stringify({
      id: "evt_async_missing_segment",
      type: "checkout.session.async_payment_succeeded",
      data: {
        object: {
          id: "cs_test_async_missing_segment",
          metadata: { founders_edition: "true" },
          payment_status: "paid",
          customer_details: { email: "customer@example.com" },
        },
      },
    });

    const response = await POST(signedRequest(body));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, upsert: "failed" });
  });

  test("async_payment_succeeded for a non-founder session does nothing", async () => {
    const body = JSON.stringify({
      id: "evt_async",
      type: "checkout.session.async_payment_succeeded",
      data: {
        object: {
          id: "cs_test_async",
          metadata: { app: "cmux", plan: "pro" },
          payment_status: "paid",
          customer_details: { email: "customer@example.com" },
        },
      },
    });

    const response = await POST(signedRequest(body));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, skipped: "async_payment" });
    expect(upsertFounderIntoSegments).not.toHaveBeenCalled();
  });

  test("no upsert happens when the welcome email itself failed", async () => {
    resendError = { name: "application_error", message: "boom" };

    const response = await POST(
      signedRequest(checkoutCompletedEvent({ founders_edition: "true" })),
    );

    expect(response.status).toBe(502);
    expect(upsertFounderIntoSegments).not.toHaveBeenCalled();
  });
});
