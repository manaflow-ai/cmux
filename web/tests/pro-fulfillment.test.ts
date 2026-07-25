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
      replyTo: "founders@manaflow.com",
      subject: "Welcome to Pro, you’re early 🎉",
      headers: { "X-Entity-Ref-ID": "pro-welcome/cs_pro_1" },
    });
    expect(payload).not.toHaveProperty("cc");
    expect(payload.text).toContain("still putting the shiny bits together");
    expect(payload.text).toContain("Every month you stay subscribed");
    expect(payload.text).toContain("Claim your spot through");
    expect(payload.text).toContain("Once you finish signing up, Apple will send");
    expect(payload.text).toContain(
      `Claim your spot: ${PRO_TESTFLIGHT_SIGNUP_URL}`,
    );
    expect(payload.html).toContain(
      `<a href="${PRO_TESTFLIGHT_SIGNUP_URL}">Sign up for TestFlight</a>`,
    );
    expect(options).toEqual({ idempotencyKey: "pro-welcome/cs_pro_1" });
  });

  test("uses the Japanese Pro copy for a Japanese checkout", () => {
    const email = buildProWelcomeEmail({
      from: "cmux Pro <pro@cmux.com>",
      to: "a@example.com",
      customerName: "山田 太郎",
      locale: "ja",
      sessionRef: "cs_ja",
    });

    expect(email.subject).toBe("cmux Pro へようこそ！");
    expect(email.text).toContain("楽しい機能をさらに磨いています");
    expect(email.text).toContain("購読いただいた月数が利用クレジット");
    expect(email.text).toContain("TestFlight 登録リンク");
    expect(email.text).toContain("登録が完了すると、Apple から");
    expect(email.text).toContain(PRO_TESTFLIGHT_SIGNUP_URL);
    expect(email.html).toContain(
      `<a href="${PRO_TESTFLIGHT_SIGNUP_URL}">TestFlight に登録する</a>`,
    );
  });

  test("sends the signup email without an ASC dependency", async () => {
    const sendEmail = mock(async () => ({ error: null }));

    await expect(
      sendProSignupWelcome(
        { session: checkoutSession(), stackUserId: "user_1" },
        {
          sendEmail,
          fromEmail: () => "pro@cmux.com",
        },
      ),
    ).resolves.toBeUndefined();
    expect(sendEmail).toHaveBeenCalledTimes(1);
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
        },
      ),
    ).rejects.toThrow("provider unavailable");
  });
});

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
