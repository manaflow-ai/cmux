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

// Route-level coverage for /api/stripe/founders-welcome. Founder's Edition
// purchases retain their personal founder welcome, while cmux Pro purchases
// are fulfilled by the separate billing webhook and must not receive this
// message as well.

// Pinned by tests/test-preload.ts before @/app/env loads.
const WEBHOOK_SECRET = process.env.STRIPE_FOUNDERS_WEBHOOK_SECRET ?? "";

type SentEmail = {
  payload: {
    subject: string;
    to: string[];
    headers: Record<string, string>;
  };
  options: { idempotencyKey: string };
};

const sentEmails: SentEmail[] = [];
let resendError: { name: string; message: string } | null = null;
const resendSend = mock(async (...args: unknown[]) => {
  sentEmails.push({
    payload: args[0] as SentEmail["payload"],
    options: args[1] as SentEmail["options"],
  });
  return { data: resendError ? null : { id: "email_1" }, error: resendError };
});

mock.module("resend", () => ({
  Resend: class MockResend {
    emails = { send: resendSend };
  },
}));

const { POST } = await import("../app/api/stripe/founders-welcome/route");

// Freeze the clock so the test's signature timestamps and the route's
// freshness check (Date.now inside POST) share one virtual time. Signature
// tolerance can then be exercised deterministically at the exact five-minute
// boundary instead of racing the real clock.
const FROZEN_NOW_MS = Date.UTC(2026, 6, 24, 12, 0, 0);
const FROZEN_NOW_SECONDS = Math.floor(FROZEN_NOW_MS / 1000);

beforeEach(() => {
  setSystemTime(FROZEN_NOW_MS);
  resendSend.mockClear();
  sentEmails.length = 0;
  resendError = null;
});

afterAll(() => {
  setSystemTime();
});

type SessionOverrides = {
  id?: string;
  metadata?: Record<string, string> | null;
  customer_details?: { email?: string | null; name?: string | null } | null;
};

function checkoutCompletedEvent(overrides: SessionOverrides = {}): string {
  return JSON.stringify({
    id: "evt_1",
    type: "checkout.session.completed",
    data: {
      object: {
        id: "cs_test_123",
        metadata: { founders_edition: "true" },
        customer_details: { email: "customer@example.com", name: "Ada Lovelace" },
        ...overrides,
      },
    },
  });
}

function signedRequest(
  body: string,
  options: { signature?: string; timestamp?: number } = {},
): Request {
  const timestamp = options.timestamp ?? FROZEN_NOW_SECONDS;
  const v1 =
    options.signature ??
    createHmac("sha256", WEBHOOK_SECRET)
      .update(`${timestamp}.${body}`)
      .digest("hex");
  return new Request("https://cmux.test/api/stripe/founders-welcome", {
    method: "POST",
    headers: { "stripe-signature": `t=${timestamp},v1=${v1}` },
    body,
  });
}

describe("founders welcome route", () => {
  test("rejects an invalid Stripe signature", async () => {
    const response = await POST(
      signedRequest(checkoutCompletedEvent(), { signature: "00".repeat(32) }),
    );

    expect(response.status).toBe(400);
    expect(resendSend).not.toHaveBeenCalled();
  });

  test("rejects a validly-signed payload older than the replay tolerance", async () => {
    const response = await POST(
      signedRequest(checkoutCompletedEvent(), {
        timestamp: FROZEN_NOW_SECONDS - 5 * 60 - 1,
      }),
    );

    expect(response.status).toBe(400);
    expect(resendSend).not.toHaveBeenCalled();
  });

  test("accepts a validly-signed payload exactly at the replay tolerance", async () => {
    const response = await POST(
      signedRequest(checkoutCompletedEvent(), {
        timestamp: FROZEN_NOW_SECONDS - 5 * 60,
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
  });

  test("acknowledges but skips non-checkout events", async () => {
    const body = JSON.stringify({ id: "evt_1", type: "invoice.paid" });
    const response = await POST(signedRequest(body));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, skipped: "event_type" });
    expect(resendSend).not.toHaveBeenCalled();
  });

  test("sends the welcome for a Founder's Edition session", async () => {
    const response = await POST(signedRequest(checkoutCompletedEvent()));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
    expect(resendSend).toHaveBeenCalledTimes(1);
  });

  test("skips a cmux Pro checkout so it receives only the separate Pro welcome", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({
          id: "cs_test_pro",
          metadata: { stackUserId: "user-1", plan: "pro", app: "cmux" },
        }),
      ),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, skipped: "pro_plan" });
    expect(resendSend).not.toHaveBeenCalled();
  });

  test("sends the identical welcome for a Team plan checkout", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({
          id: "cs_test_team",
          metadata: { stackTeamId: "team-1", plan: "team", app: "cmux" },
        }),
      ),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
    expect(resendSend).toHaveBeenCalledTimes(1);
    expect(sentEmails[0].options.idempotencyKey).toBe(
      "founders-welcome/cs_test_team",
    );
  });

  test("sends the welcome for any other completed checkout (no recognized metadata)", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({
          id: "cs_test_other",
          metadata: { plan: "pro", app: "other" },
        }),
      ),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
    expect(resendSend).toHaveBeenCalledTimes(1);
    expect(sentEmails[0].options.idempotencyKey).toBe(
      "founders-welcome/cs_test_other",
    );
  });

  test("skips a session without a customer email", async () => {
    const response = await POST(
      signedRequest(checkoutCompletedEvent({ customer_details: null })),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      skipped: "no_customer_email",
    });
    expect(resendSend).not.toHaveBeenCalled();
  });

  test("returns non-2xx when Resend fails so Stripe retries", async () => {
    resendError = { name: "application_error", message: "boom" };

    const response = await POST(signedRequest(checkoutCompletedEvent()));

    expect(response.status).toBe(502);
    expect(resendSend).toHaveBeenCalledTimes(1);
  });
});
