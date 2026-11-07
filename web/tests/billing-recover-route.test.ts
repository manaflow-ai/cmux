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
    afterResponse: mock(() => undefined),
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

function queuedHandler(deps = dependencies()) {
  const tasks: Array<() => Promise<void>> = [];
  const scheduled = { ...deps, afterResponse: (task: () => Promise<void>) => { tasks.push(task); } };
  return { tasks, handle: makeBillingRecoveryHandler(scheduled) };
}

// Existing delivery assertions run the response and then the scheduled work.
function completingHandler(deps = dependencies()) {
  const { tasks, handle } = queuedHandler(deps);
  return async (input: Request) => {
    const response = await handle(input);
    for (const task of tasks.splice(0)) await task();
    return response;
  };
}

describe("billing recovery response boundary", () => {
  test("delivers the complete generic body before looking up account state", async () => {
    const deps = dependencies();
    const { handle, tasks } = queuedHandler(deps);
    const response = await handle(request("fixture@example.invalid"));

    expect(response.status).toBe(202);
    expect(response.headers.get("content-type")?.split(";")[0]).toBe("application/json");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("location")).toBeNull();
    const bytes = await response.arrayBuffer();
    expect(bytes.byteLength).toBeGreaterThan(0);
    expect(JSON.parse(new TextDecoder().decode(bytes))).toEqual(acceptedResponse());
    expect(deps.recoverPaid).not.toHaveBeenCalled();
    expect(deps.sendVerification).not.toHaveBeenCalled();
    expect(tasks).toHaveLength(1);

    await tasks[0]();
    expect(deps.recoverPaid).toHaveBeenCalledTimes(1);
    expect(deps.sendVerification).toHaveBeenCalledTimes(1);
  });

  test("fails closed when post-response work cannot be registered", async () => {
    const deps = {
      ...dependencies(),
      afterResponse: () => { throw new Error("request lifecycle unavailable"); },
    };
    const response = await makeBillingRecoveryHandler(deps)(request("fixture@example.invalid"));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "recovery_unavailable" });
    expect(deps.recoverPaid).not.toHaveBeenCalled();
    expect(deps.sendMagicLink).not.toHaveBeenCalled();
    expect(deps.sendVerification).not.toHaveBeenCalled();
  });

  test("never schedules invalid or throttled requests", async () => {
    for (const [email, deps, status] of [
      ["invalid", dependencies(), 400],
      ["fixture@example.invalid", dependencies({ checkRateLimit: mock(async () => ({ rateLimited: true })) }), 429],
      ["fixture@example.invalid", dependencies({ rateLimitRuleID: () => undefined }), 503],
      ["fixture@example.invalid", dependencies({ checkRateLimit: mock(async () => ({ rateLimited: false, error: "blocked" as const })) }), 429],
      ["fixture@example.invalid", dependencies({ checkRateLimit: mock(async () => { throw new Error("limiter unavailable"); }) }), 503],
    ] as const) {
      const { handle, tasks } = queuedHandler(deps);
      const response = await handle(request(email));
      expect(response.status).toBe(status);
      expect(tasks).toHaveLength(0);
      expect(deps.recoverPaid).not.toHaveBeenCalled();
    }
  });
});

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
    const response = await completingHandler(
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
    const response = await completingHandler(
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
    const response = await completingHandler(
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
    const response = await completingHandler(
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
    const response = await completingHandler(
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
    const response = await completingHandler(deps)(
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
    const paid = await completingHandler(
      dependencies({ recoverPaid: mock(async () => true) }),
    )(request("paid@example.com"));
    const unpaid = await completingHandler(
      dependencies({ recoverPaid: mock(async () => false) }),
    )(request("unpaid@example.com"));

    expect(paid.status).toBe(unpaid.status);
    expect(await paid.text()).toBe(await unpaid.text());
  });

  test("localizes the generic response from Accept-Language", async () => {
    const response = await completingHandler(dependencies())(
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
    const japanese = await completingHandler(dependencies())(
      japaneseRequest,
    );
    expect(await japanese.json()).toEqual(
      acceptedResponse("アカウントが見つかった場合は、メールで次の手順をご確認ください"),
    );
  });

  test("keeps the valid-address response uniform when a provider fails", async () => {
    const response = await completingHandler(
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
    const response = await completingHandler(
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
    const response = await completingHandler(deps)(
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
    const response = await completingHandler(deps)(
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
