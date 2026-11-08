import { describe, expect, test } from "bun:test";

import { personalProWelcomeOwnsDelivery } from "../services/billing/personalProWelcome";

describe("personal Pro welcome rollout", () => {
  const configured = {
    resendApiKey: "re_test",
    webhookSecret: "whsec_test",
    stripeSecretKey: "sk_test",
  };

  test("keeps the durable billing-webhook sender when the rollout flag is absent", () => {
    expect(
      personalProWelcomeOwnsDelivery({
        ...configured,
        enabled: undefined,
      }),
    ).toBe(false);
  });

  test("moves delivery only when the explicit rollout and all dependencies are configured", () => {
    expect(
      personalProWelcomeOwnsDelivery({
        ...configured,
        enabled: "1",
      }),
    ).toBe(true);
  });

  test("keeps the durable sender when Stripe retrieval is not configured", () => {
    expect(
      personalProWelcomeOwnsDelivery({
        ...configured,
        stripeSecretKey: undefined,
        enabled: "1",
      }),
    ).toBe(false);
  });
});
