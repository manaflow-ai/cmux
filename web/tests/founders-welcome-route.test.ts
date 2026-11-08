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

// Route-level coverage for /api/stripe/founders-welcome. Founder's Edition and
// Pro purchases receive the personal message; Team and unrelated checkouts are
// acknowledged without mail.

// Pinned by tests/test-preload.ts before @/app/env loads.
const WEBHOOK_SECRET = process.env.STRIPE_FOUNDERS_WEBHOOK_SECRET ?? "";

type SentEmail = {
  payload: {
    from: string;
    subject: string;
    to: string[];
    cc: string[];
    replyTo: string;
    text: string;
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

let personalProWelcomeEnabled = true;
let subscriptionRetrieveError: Error | null = null;
let retrievedSubscription: Record<string, unknown> = {
  id: "sub_test_pro",
  metadata: { stackUserId: "user-1", plan: "pro", app: "cmux" },
};
const retrieveSubscription = mock(
  async (...args: unknown[]): Promise<{
    metadata?: Record<string, string> | null;
  }> => {
    void args;
    if (subscriptionRetrieveError) throw subscriptionRetrieveError;
    return retrievedSubscription as {
      metadata?: Record<string, string> | null;
    };
  },
);

const { makeFoundersWelcomeHandler } = await import(
  "../app/api/stripe/founders-welcome/route"
);
const POST = makeFoundersWelcomeHandler({
  personalProWelcomeEnabled: () => personalProWelcomeEnabled,
  retrieveSubscription: retrieveSubscription as unknown as (
    subscriptionId: string,
  ) => Promise<{ metadata?: Record<string, string> | null }>,
});

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
  personalProWelcomeEnabled = true;
  subscriptionRetrieveError = null;
  retrievedSubscription = {
    id: "sub_test_pro",
    metadata: { stackUserId: "user-1", plan: "pro", app: "cmux" },
  };
  retrieveSubscription.mockClear();
});

afterAll(() => {
  setSystemTime();
});

type SessionOverrides = {
  id?: string;
  metadata?: Record<string, string> | null;
  subscription?: string | { metadata?: Record<string, string> | null } | null;
  customer_details?: { email?: string | null; name?: string | null } | null;
  payment_status?: string | null;
  locale?: string | null;
};

function checkoutCompletedEvent(
  overrides: SessionOverrides = {},
  eventType = "checkout.session.completed",
): string {
  return JSON.stringify({
    id: "evt_1",
    type: eventType,
    data: {
      object: {
        id: "cs_test_123",
        metadata: { founders_edition: "true" },
        customer_details: { email: "customer@example.com", name: "Sample Buyer" },
        payment_status: "paid",
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

  test("sends the personal Pro email with the Pro subject", async () => {
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
    expect(sentEmails[0].payload.subject).toBe("Welcome to cmux Pro 🎉");
    expect(sentEmails[0].payload.from).toBe(
      "Austin Wang <austin@manaflow.ai>",
    );
    expect(sentEmails[0].payload.to).toEqual(["customer@example.com"]);
    expect(sentEmails[0].payload.cc).toEqual([
      "austin@manaflow.ai",
      "lawrence@manaflow.ai",
    ]);
    expect(sentEmails[0].payload.replyTo).toBe("austin@manaflow.ai");
    expect(sentEmails[0].payload.text).toContain("Thanks for joining cmux Pro!");
    expect(sentEmails[0].payload.text).toContain(
      "Sign up for TestFlight: https://cmux.com/dashboard/testflight",
    );
    expect(sentEmails[0].payload.headers["X-Entity-Ref-ID"]).toBe(
      "founders-welcome/cs_test_pro",
    );
    expect(sentEmails[0].options.idempotencyKey).toBe(
      "founders-welcome/cs_test_pro",
    );
  });

  test("preserves regional locale keys and accepts lowercase Stripe aliases", async () => {
    const cases = [
      { locale: "pt-BR", subject: "Boas-vindas ao cmux Pro 🎉" },
      { locale: "zh-cn", subject: "欢迎加入 cmux Pro 🎉" },
      { locale: "zh-TW", subject: "歡迎加入 cmux Pro 🎉" },
    ];

    for (const [index, testCase] of cases.entries()) {
      const response = await POST(
        signedRequest(
          checkoutCompletedEvent({
            id: `cs_test_regional_${index}`,
            metadata: { stackUserId: "user-1", plan: "pro", app: "cmux" },
            locale: testCase.locale,
          }),
        ),
      );

      expect(response.status).toBe(200);
      expect(sentEmails[index]?.payload.subject).toBe(testCase.subject);
    }
    expect(resendSend).toHaveBeenCalledTimes(cases.length);
  });

  test("sends the personal Pro email when metadata is only on the expanded subscription", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({
          id: "cs_test_pro_subscription_metadata",
          metadata: {},
          subscription: {
            metadata: { stackUserId: "user-1", plan: "pro", app: "cmux" },
          },
        }),
      ),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
    expect(resendSend).toHaveBeenCalledTimes(1);
    expect(sentEmails[0].payload.subject).toBe("Welcome to cmux Pro 🎉");
  });

  test("retrieves subscription metadata when Stripe sends only a subscription id", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({
          id: "cs_test_pro_subscription_id",
          metadata: {},
          subscription: "sub_test_pro",
        }),
      ),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, sent: true });
    expect(retrieveSubscription).toHaveBeenCalledWith("sub_test_pro");
    expect(sentEmails[0].payload.subject).toBe("Welcome to cmux Pro 🎉");
  });

  test("keeps Stripe retryable when subscription metadata cannot be retrieved", async () => {
    subscriptionRetrieveError = new Error("Stripe unavailable");

    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({
          id: "cs_test_pro_subscription_failure",
          metadata: {},
          subscription: "sub_test_pro",
        }),
      ),
    );

    expect(response.status).toBe(503);
    expect(resendSend).not.toHaveBeenCalled();
  });

  test("skips Pro delivery until its explicit rollout flag is enabled", async () => {
    personalProWelcomeEnabled = false;

    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({
          id: "cs_test_pro_rollout_disabled",
          metadata: { stackUserId: "user-1", plan: "pro", app: "cmux" },
        }),
      ),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      skipped: "pro_rollout_disabled",
    });
    expect(resendSend).not.toHaveBeenCalled();
  });

  test("also sends the personal Pro email after an async payment succeeds", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent(
          {
            id: "cs_test_pro_async",
            metadata: { stackUserId: "user-1", plan: "pro", app: "cmux" },
          },
          "checkout.session.async_payment_succeeded",
        ),
      ),
    );

    expect(response.status).toBe(200);
    expect(resendSend).toHaveBeenCalledTimes(1);
    expect(sentEmails[0].options.idempotencyKey).toBe(
      "founders-welcome/cs_test_pro_async",
    );
  });

  test("does not send a welcome for an unsettled completed Pro checkout", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({
          id: "cs_test_pro_pending",
          metadata: { stackUserId: "user-1", plan: "pro", app: "cmux" },
          payment_status: "unpaid",
        }),
      ),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, skipped: "payment_pending" });
    expect(resendSend).not.toHaveBeenCalled();
  });

  test("skips a Team plan checkout", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({
          id: "cs_test_team",
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

  test("skips any other completed checkout (no recognized metadata)", async () => {
    const response = await POST(
      signedRequest(
        checkoutCompletedEvent({
          id: "cs_test_other",
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
