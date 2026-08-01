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

// Route-level coverage for the purchase-time newsletter audience upsert in
// /api/stripe/founders-welcome: it runs only for Founder's Edition sessions,
// and a failure inside it never turns a delivered welcome email into a
// webhook error (which would trigger Stripe retries).

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
const upsertFounderIntoAudiences = mock(async (...args: unknown[]) => {
  const options = args[0] as UpsertCall;
  upsertCalls.push({
    email: options.email,
    customerName: options.customerName,
  });
  if (upsertError) {
    throw upsertError;
  }
  return [];
});

mock.module("@/services/newsletter/founder-hook", () => ({
  upsertFounderIntoAudiences,
}));

const { POST } = await import("../app/api/stripe/founders-welcome/route");

const FROZEN_NOW_MS = Date.UTC(2026, 6, 24, 12, 0, 0);
const FROZEN_NOW_SECONDS = Math.floor(FROZEN_NOW_MS / 1000);

beforeEach(() => {
  setSystemTime(FROZEN_NOW_MS);
  resendSend.mockClear();
  resendError = null;
  upsertFounderIntoAudiences.mockClear();
  upsertCalls.length = 0;
  upsertError = null;
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
  email = "customer@example.com",
): string {
  return JSON.stringify({
    id: "evt_1",
    type: "checkout.session.completed",
    data: {
      object: {
        id: "cs_test_123",
        metadata,
        customer_details: { email, name: "Ada Lovelace" },
      },
    },
  });
}

describe("founders welcome audience upsert", () => {
  test("upserts the buyer into the audiences for a Founder's Edition session", async () => {
    const response = await POST(
      signedRequest(checkoutCompletedEvent({ founders_edition: "true" })),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
    expect(upsertCalls).toEqual([
      { email: "customer@example.com", customerName: "Ada Lovelace" },
    ]);
  });

  test("does not touch audiences for non-founder checkouts", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({ app: "cmux", plan: "team" }),
      ),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
    expect(upsertFounderIntoAudiences).not.toHaveBeenCalled();
  });

  test("an audience upsert failure never fails the webhook", async () => {
    upsertError = new Error("resend audience API down");

    const response = await POST(
      signedRequest(checkoutCompletedEvent({ founders_edition: "true" })),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
    expect(upsertFounderIntoAudiences).toHaveBeenCalledTimes(1);
  });

  test("no upsert happens when the welcome email itself failed", async () => {
    resendError = { name: "application_error", message: "boom" };

    const response = await POST(
      signedRequest(checkoutCompletedEvent({ founders_edition: "true" })),
    );

    expect(response.status).toBe(502);
    expect(upsertFounderIntoAudiences).not.toHaveBeenCalled();
  });
});
