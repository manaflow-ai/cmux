import { beforeEach, describe, expect, mock, test } from "bun:test";

import {
  makeBillingRecoveryHandler,
  type BillingRecoveryRouteDependencies,
} from "../app/api/billing/recover/route";

function request(
  email: string,
  url = "https://cmux.test/api/billing/recover",
): Request {
  return new Request(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email }),
  });
}

function dependencies(
  overrides: Partial<BillingRecoveryRouteDependencies> = {},
): BillingRecoveryRouteDependencies {
  return {
    recoverPaid: mock(async () => false),
    sendMagicLink: mock(async () => undefined),
    sendVerification: mock(async () => ({ delivery: "accepted" as const })),
    checkRateLimit: mock(async () => ({ rateLimited: false })),
    rateLimitRuleID: () => "billing-recovery-limit",
    isVercel: () => true,
    ...overrides,
  };
}

function acceptedResponse(message = "If we found an account, check your email for next steps") {
  return { accepted: true, delivery: "unconfirmed", retryable: true, message };
}

describe("billing recovery route", () => {
  beforeEach(() => {
    delete process.env.VERCEL;
  });

  test("provisions a paid dotted Gmail purchase and sends recovery mail", async () => {
    const recoverPaid = mock(async (...args: unknown[]) => {
      const email = args[0] as string;
      expect(email).toBe("Billing.Fixture@Gmail.com");
      return true;
    }) as unknown as BillingRecoveryRouteDependencies["recoverPaid"];
    const sendMagicLink = mock(async () => undefined);
    const sendVerification = mock(async () => ({ delivery: "accepted" as const }));
    const response = await makeBillingRecoveryHandler(
      dependencies({ recoverPaid, sendMagicLink, sendVerification }),
    )(request(" Billing.Fixture@Gmail.com "));

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual(acceptedResponse());
    expect(recoverPaid).toHaveBeenCalledWith("Billing.Fixture@Gmail.com");
    expect(sendMagicLink).toHaveBeenCalledWith({
      email: "Billing.Fixture@Gmail.com",
      callbackURL: "https://cmux.com/handler/after-sign-in",
    });
    expect(sendVerification).not.toHaveBeenCalled();
  });

  test("uses the provisioned account's literal email for a Gmail alias", async () => {
    const sendMagicLink = mock(async () => undefined);
    const response = await makeBillingRecoveryHandler(
      dependencies({
        recoverPaid: mock(async () => ({
          deliveryEmail: "billingfixture@gmail.com",
        })),
        sendMagicLink,
      }),
    )(request("billing.fixture@gmail.com"));

    expect(response.status).toBe(202);
    expect(sendMagicLink).toHaveBeenCalledWith({
      email: "billingfixture@gmail.com",
      callbackURL: "https://cmux.com/handler/after-sign-in",
    });
  });

  test("does not send a second link when provisioning used the delivery ledger", async () => {
    const sendMagicLink = mock(async () => undefined);
    const response = await makeBillingRecoveryHandler(
      dependencies({
        recoverPaid: mock(async () => ({
          deliveryEmail: "buyer@example.com",
          deliveryHandled: true,
        })),
        sendMagicLink,
      }),
    )(request("buyer@example.com"));

    expect(response.status).toBe(202);
    expect(sendMagicLink).not.toHaveBeenCalled();
  });

  test("does not send authentication mail when paid provisioning is blocked", async () => {
    const sendMagicLink = mock(async () => undefined);
    const sendVerification = mock(async () => ({
      delivery: "accepted" as const,
    }));
    const response = await makeBillingRecoveryHandler(
      dependencies({
        recoverPaid: mock(async () => ({
          skipped: "account_deletion_in_progress" as const,
        })),
        sendMagicLink,
        sendVerification,
      }),
    )(request("deleting@example.com"));

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual(acceptedResponse());
    expect(sendMagicLink).not.toHaveBeenCalled();
    expect(sendVerification).not.toHaveBeenCalled();
  });

  test("returns a retryable response when a paid purchase has no delivery email", async () => {
    const sendMagicLink = mock(async () => undefined);
    const sendVerification = mock(async () => ({
      delivery: "accepted" as const,
    }));
    const response = await makeBillingRecoveryHandler(
      dependencies({
        recoverPaid: mock(async () => ({
          skipped: "no_customer_email" as const,
        })),
        sendMagicLink,
        sendVerification,
      }),
    )(request("buyer@example.com"));

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual(acceptedResponse());
    expect(sendMagicLink).not.toHaveBeenCalled();
    expect(sendVerification).not.toHaveBeenCalled();
  });

  test("sends standard verification when no paid purchase is found", async () => {
    const deps = dependencies();
    const response = await makeBillingRecoveryHandler(deps)(
      request("buyer@example.com"),
    );

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual(acceptedResponse());
    expect(deps.sendVerification).toHaveBeenCalledWith({
      email: "buyer@example.com",
      callbackURL: "https://cmux.com/handler/email-verification",
    });
    expect(deps.sendMagicLink).not.toHaveBeenCalled();
  });

  test("keeps paid and unpaid outcomes indistinguishable", async () => {
    const paid = await makeBillingRecoveryHandler(
      dependencies({ recoverPaid: mock(async () => true) }),
    )(request("paid@example.com"));
    const unpaid = await makeBillingRecoveryHandler(
      dependencies({ recoverPaid: mock(async () => false) }),
    )(request("unpaid@example.com"));

    expect(paid.status).toBe(unpaid.status);
    expect(await paid.text()).toBe(await unpaid.text());
  });

  test("localizes the generic response from Accept-Language", async () => {
    const response = await makeBillingRecoveryHandler(dependencies())(
      request("buyer@example.com").clone(),
    );

    // The route remains generic; only the locale-specific wording changes.
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual(acceptedResponse());

    const japaneseRequest = new Request(
      "https://cmux.test/api/billing/recover",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "accept-language": "ja-JP, en;q=0.8",
        },
        body: JSON.stringify({ email: "buyer@example.com" }),
      },
    );
    const japanese = await makeBillingRecoveryHandler(dependencies())(
      japaneseRequest,
    );
    expect(await japanese.json()).toEqual(
      acceptedResponse("アカウントが見つかった場合は、メールで次の手順をご確認ください"),
    );
  });

  test("keeps the valid-address response uniform when a provider fails", async () => {
    const response = await makeBillingRecoveryHandler(
      dependencies({
        recoverPaid: mock(async () => {
          throw new Error("provider unavailable");
        }),
      }),
    )(request("buyer@example.com"));

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual(acceptedResponse());
  });

  test("fails closed on the aggressive deployed rate limit", async () => {
    const recoverPaid = mock(async () => true);
    const response = await makeBillingRecoveryHandler(
      dependencies({
        recoverPaid,
        isVercel: () => true,
        checkRateLimit: mock(async () => ({ rateLimited: true })),
      }),
    )(request("buyer@example.com"));

    expect(response.status).toBe(429);
    expect(recoverPaid).not.toHaveBeenCalled();
  });

  test("fails closed outside Vercel instead of sending unthrottled mail", async () => {
    const deps = dependencies({
      isVercel: () => false,
    });
    const response = await makeBillingRecoveryHandler(deps)(
      request("buyer@example.com"),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "recovery_unavailable" });
    expect(deps.checkRateLimit).not.toHaveBeenCalled();
    expect(deps.recoverPaid).not.toHaveBeenCalled();
    expect(deps.sendVerification).not.toHaveBeenCalled();
  });

  test("rejects malformed input without sending mail", async () => {
    const deps = dependencies();
    const response = await makeBillingRecoveryHandler(deps)(
      new Request("https://cmux.test/api/billing/recover", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email: "not-an-email" }),
      }),
    );

    expect(response.status).toBe(400);
    expect(deps.recoverPaid).not.toHaveBeenCalled();
    expect(deps.sendVerification).not.toHaveBeenCalled();
  });
});
