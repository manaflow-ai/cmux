import { describe, expect, mock, test } from "bun:test";
import type Stripe from "stripe";

import {
  buildProWelcomeEmail,
  sendProSignupWelcome,
  PRO_TESTFLIGHT_SIGNUP_URL,
} from "../services/billing/proFulfillment";

describe("cmux Pro checkout fulfillment", () => {
  test("sends a separate Pro welcome with signup link without auto-enrolling", async () => {
    const calls: string[] = [];
    const sendEmail = mock(async () => {
      calls.push("email");
      return { error: null };
    });

    await sendProSignupWelcome(
      {
        session: checkoutSession(),
        stackUserId: "user_1",
      },
      {
        sendEmail,
        fromEmail: () => "pro@cmux.com",
        fulfillmentStore: inMemoryProWelcomeFulfillmentStore(),
      },
    );

    expect(calls).toEqual(["email"]);
    expect(sendEmail).toHaveBeenCalledTimes(1);
    const [payload, options] = (sendEmail as unknown as {
      mock: { calls: [[Record<string, unknown>, Record<string, unknown>]] };
    }).mock.calls[0];
    expect(payload).toMatchObject({
      from: "cmux Pro <pro@cmux.com>",
      to: ["ada@example.com"],
      replyTo: "pro@cmux.com",
      subject: "Welcome to cmux Pro 🎉",
      headers: { "X-Entity-Ref-ID": "pro-welcome/cs_pro_1" },
    });
    expect(payload).not.toHaveProperty("cc");
    expect(JSON.stringify(payload)).not.toContain("founders@");
    expect(payload.text).toContain("still putting the full Pro experience together");
    expect(payload.text).toContain("based on how many months you’ve been subscribed");
    expect(payload.text).toContain("Sign up through the link below");
    expect(payload.text).toContain("Apple will send your TestFlight invitation");
    expect(payload.text).toContain(
      `Sign up for TestFlight: ${PRO_TESTFLIGHT_SIGNUP_URL}`,
    );
    expect(payload.html).toContain(
      `<a href="${PRO_TESTFLIGHT_SIGNUP_URL}">Sign up for TestFlight</a>`,
    );
    expect(options).toEqual({ idempotencyKey: "pro-welcome/cs_pro_1" });
  });

  test("uses the Japanese Pro copy for a Japanese checkout", async () => {
    const email = await buildProWelcomeEmail({
      from: "cmux Pro <pro@cmux.com>",
      to: "a@example.com",
      customerName: "山田 太郎",
      locale: "ja",
      sessionRef: "cs_ja",
    });

    expect(email.subject).toBe("cmux Pro へようこそ！");
    expect(email.text).toContain("Pro の全体的な体験を準備");
    expect(email.text).toContain("購読いただいた月数に応じた利用クレジット");
    expect(email.text).toContain("下のリンクから登録");
    expect(email.text).toContain("Apple から TestFlight の招待");
    expect(email.text).toContain(PRO_TESTFLIGHT_SIGNUP_URL);
    expect(email.html).toContain(
      `<a href="${PRO_TESTFLIGHT_SIGNUP_URL}">TestFlight に登録する</a>`,
    );
  });

  test("uses a supported checkout locale for the Pro email", async () => {
    const sendEmail = mock(async () => ({ error: null }));
    const session = checkoutSession();
    session.locale = "fr";

    await sendProSignupWelcome(
      { session, stackUserId: "user_1" },
      {
        sendEmail,
        fromEmail: () => "pro@cmux.com",
        fulfillmentStore: inMemoryProWelcomeFulfillmentStore(),
      },
    );

    const [payload] = (sendEmail as unknown as {
      mock: { calls: [[Record<string, unknown>]] };
    }).mock.calls[0];
    expect(payload.subject).toBe("Bienvenue dans cmux Pro 🎉");
    expect(payload.text).toContain("L’accès au cloud arrive bientôt");
  });

  test("escapes the customer name in the HTML email", async () => {
    const email = await buildProWelcomeEmail({
      from: "cmux Pro <pro@cmux.com>",
      to: "a@example.com",
      customerName: `<script>&"'`,
      locale: "en",
      sessionRef: "cs_escape",
    });

    expect(email.html).toContain("Hey &lt;script&gt;&amp;&quot;&#39;,");
    expect(email.html).not.toContain("<script>");
  });

  test("sends the signup email without an ASC dependency", async () => {
    const sendEmail = mock(async () => ({ error: null }));

    await expect(
      sendProSignupWelcome(
        { session: checkoutSession(), stackUserId: "user_1" },
        {
          sendEmail,
          fromEmail: () => "pro@cmux.com",
          fulfillmentStore: inMemoryProWelcomeFulfillmentStore(),
        },
      ),
    ).resolves.toBeUndefined();
    expect(sendEmail).toHaveBeenCalledTimes(1);
  });

  test("acknowledges a checkout without an email instead of retrying forever", async () => {
    const sendEmail = mock(async () => ({ error: null }));
    const session = checkoutSession();
    session.customer_details = null;
    session.customer = null;

    await expect(
      sendProSignupWelcome(
        { session, stackUserId: "user_1" },
        {
          sendEmail,
          fromEmail: () => "pro@cmux.com",
          fulfillmentStore: inMemoryProWelcomeFulfillmentStore(),
        },
      ),
    ).resolves.toBeUndefined();
    expect(sendEmail).not.toHaveBeenCalled();
  });

  test("fails the checkout event when the Pro email provider rejects the send", async () => {
    await expect(
      sendProSignupWelcome(
        { session: checkoutSession(), stackUserId: "user_1" },
        {
          sendEmail: mock(async () => ({
            error: { message: "provider unavailable" },
          })),
          fromEmail: () => "pro@cmux.com",
          fulfillmentStore: inMemoryProWelcomeFulfillmentStore(),
        },
      ),
    ).rejects.toThrow("provider unavailable");
  });

  test("sends once across different webhook events for the same checkout", async () => {
    const sendEmail = mock(async () => ({ error: null }));
    const fulfillmentStore = inMemoryProWelcomeFulfillmentStore();
    const input = {
      session: checkoutSession(),
      stackUserId: "user_1",
    };
    const dependencies = {
      sendEmail,
      fromEmail: () => "pro@cmux.com",
      fulfillmentStore,
    };

    await sendProSignupWelcome(input, dependencies as never);
    await sendProSignupWelcome(input, dependencies as never);

    expect(sendEmail).toHaveBeenCalledTimes(1);
  });
});

function inMemoryProWelcomeFulfillmentStore() {
  const sentCheckoutSessions = new Set<string>();
  return {
    deliverOnce: async (
      input: {
        readonly checkoutSessionId: string;
        readonly stackUserId: string;
      },
      deliver: () => Promise<void>,
    ) => {
      if (sentCheckoutSessions.has(input.checkoutSessionId)) {
        return "already_sent" as const;
      }
      await deliver();
      sentCheckoutSessions.add(input.checkoutSessionId);
      return "sent" as const;
    },
  };
}

function checkoutSession(): Stripe.Checkout.Session {
  return {
    id: "cs_pro_1",
    locale: "en",
    customer_details: {
      email: " Ada@Example.com ",
      name: "Ada Lovelace",
    },
  } as Stripe.Checkout.Session;
}
