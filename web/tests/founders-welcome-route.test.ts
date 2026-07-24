import { createHmac } from "node:crypto";

import { beforeEach, describe, expect, mock, test } from "bun:test";

// Route-level coverage for /api/stripe/founders-welcome. The webhook must send
// the identical welcome email for BOTH qualifying checkout shapes — Founder's
// Edition payment-link sessions (founders_edition=true) and cmux Pro
// subscription checkouts ({ app: "cmux", plan: "pro" }, no founders key) —
// while skipping everything else. Pro coverage is a regression guard: before
// the pro_plan trigger, Pro sessions were skipped as not-founders and a real
// Pro subscriber never received the welcome.

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

beforeEach(() => {
  resendSend.mockClear();
  sentEmails.length = 0;
  resendError = null;
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

function signedRequest(body: string, signature?: string): Request {
  const timestamp = Math.floor(Date.now() / 1000);
  const v1 =
    signature ??
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
      signedRequest(checkoutCompletedEvent(), "00".repeat(32)),
    );

    expect(response.status).toBe(400);
    expect(resendSend).not.toHaveBeenCalled();
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

  test("sends the identical welcome for a cmux Pro checkout (no founders key)", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({
          id: "cs_test_pro",
          metadata: { stackUserId: "user-1", plan: "pro", app: "cmux" },
        }),
      ),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
    expect(resendSend).toHaveBeenCalledTimes(1);

    // Same builder, same idempotency/threading keyed by the session id — a
    // Pro welcome is indistinguishable from a founders welcome apart from the
    // per-session ref.
    const { payload, options } = sentEmails[0];
    expect(payload.subject).toBe("cmux Founder's Edition");
    expect(payload.to).toEqual(["customer@example.com"]);
    expect(payload.headers["X-Entity-Ref-ID"]).toBe(
      "founders-welcome/cs_test_pro",
    );
    expect(options.idempotencyKey).toBe("founders-welcome/cs_test_pro");
  });

  test("skips a Team plan checkout", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({
          metadata: { stackTeamId: "team-1", plan: "team", app: "cmux" },
        }),
      ),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      skipped: "not_welcome_eligible",
    });
    expect(resendSend).not.toHaveBeenCalled();
  });

  test("skips a pro plan for a different app", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({
          metadata: { plan: "pro", app: "other" },
        }),
      ),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      skipped: "not_welcome_eligible",
    });
    expect(resendSend).not.toHaveBeenCalled();
  });

  test("skips an eligible session without a customer email", async () => {
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
