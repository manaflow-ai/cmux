import { describe, expect, mock, test } from "bun:test";
import type Stripe from "stripe";

import {
  buildProWelcomeEmail,
  fulfillProCheckout,
} from "../services/billing/proFulfillment";

describe("cmux Pro checkout fulfillment", () => {
  test("enrolls TestFlight before sending a separate Pro welcome", async () => {
    const calls: string[] = [];
    const enrollTester = mock(async () => {
      calls.push("testflight");
    });
    const sendEmail = mock(async () => {
      calls.push("email");
      return { error: null };
    });

    await fulfillProCheckout(
      {
        session: checkoutSession(),
        stackUserId: "user_1",
      },
      {
        isAscConfigured: () => true,
        enrollTester,
        sendEmail,
        fromEmail: () => "pro@cmux.com",
      },
    );

    expect(calls).toEqual(["testflight", "email"]);
    expect(enrollTester).toHaveBeenCalledWith(
      "ada@example.com",
      "Ada",
      "Lovelace",
    );
    expect(sendEmail).toHaveBeenCalledTimes(1);
    const [payload, options] = (sendEmail as unknown as {
      mock: { calls: [[Record<string, unknown>, Record<string, unknown>]] };
    }).mock.calls[0];
    expect(payload).toMatchObject({
      from: "cmux Pro <pro@cmux.com>",
      to: ["ada@example.com"],
      replyTo: "founders@manaflow.com",
      subject: "You’re in! Welcome to cmux Pro",
      headers: { "X-Entity-Ref-ID": "pro-welcome/cs_pro_1" },
    });
    expect(payload).not.toHaveProperty("cc");
    expect(payload.text).toContain("still building out the full Pro experience");
    expect(payload.text).toContain("based on how many months you’ve been subscribed");
    expect(payload.text).toContain("cmux iOS beta through TestFlight");
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
    expect(email.text).toContain("Pro の体験をさらに充実させるため開発を進めており");
    expect(email.text).toContain("購読いただいた月数に応じて利用クレジット");
    expect(email.text).toContain("TestFlight を通じた cmux iOS ベータ");
    expect(email.text).toContain("別の招待メール");
  });

  test("fails the checkout event when TestFlight is unavailable", async () => {
    const sendEmail = mock(async () => ({ error: null }));

    await expect(
      fulfillProCheckout(
        { session: checkoutSession(), stackUserId: "user_1" },
        {
          isAscConfigured: () => false,
          enrollTester: mock(async () => {}),
          sendEmail,
          fromEmail: () => "pro@cmux.com",
        },
      ),
    ).rejects.toThrow("TestFlight enrollment is not configured");
    expect(sendEmail).not.toHaveBeenCalled();
  });

  test("fails the checkout event when the Pro email provider rejects the send", async () => {
    await expect(
      fulfillProCheckout(
        { session: checkoutSession(), stackUserId: "user_1" },
        {
          isAscConfigured: () => true,
          enrollTester: mock(async () => {}),
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
