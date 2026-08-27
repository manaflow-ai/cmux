import { describe, expect, mock, test } from "bun:test";

import {
  makeEmailVerificationRecoveryHandler,
  type EmailVerificationRecoveryRouteDependencies,
} from "../app/api/auth/email-verification/route";

function request(
  body: unknown,
  url = "https://cmux.com/api/auth/email-verification",
): Request {
  return new Request(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

function dependencies(
  overrides: Partial<EmailVerificationRecoveryRouteDependencies> = {},
): EmailVerificationRecoveryRouteDependencies {
  return {
    recover: mock(async () => ({ delivery: "sent" as const })),
    checkRateLimit: mock(async () => ({ rateLimited: false })),
    rateLimitRuleID: () => "recovery-limit",
    isVercel: () => false,
    ...overrides,
  };
}

describe("email verification recovery route", () => {
  test("accepts both sent and undisclosed no-match outcomes", async () => {
    for (const delivery of ["sent", "accepted"] as const) {
      const recover = mock(async () => ({ delivery }));
      const response = await makeEmailVerificationRecoveryHandler(
        dependencies({ recover }),
      )(request({ email: "Buyer@Example.com" }));

      expect(response.status).toBe(202);
      expect(await response.json()).toEqual({ ok: true });
      expect(recover).toHaveBeenCalledWith({
        email: "Buyer@Example.com",
        callbackURL: "https://cmux.com/handler/email-verification",
      });
    }
  });

  test("rejects malformed email without calling Stack", async () => {
    const recover = mock(async () => ({ delivery: "sent" as const }));
    const response = await makeEmailVerificationRecoveryHandler(
      dependencies({ recover }),
    )(request({ email: "not-an-email" }));

    expect(response.status).toBe(400);
    expect(recover).not.toHaveBeenCalled();
  });

  test("keeps an IPv6 loopback verification callback local", async () => {
    const recover = mock(async () => ({ delivery: "sent" as const }));
    const response = await makeEmailVerificationRecoveryHandler(
      dependencies({ recover }),
    )(
      request(
        { email: "buyer@example.com" },
        "http://[::1]:3777/api/auth/email-verification",
      ),
    );

    expect(response.status).toBe(202);
    expect(recover).toHaveBeenCalledWith({
      email: "buyer@example.com",
      callbackURL: "http://[::1]:3777/handler/email-verification",
    });
  });

  test("enforces the deployed public-endpoint rate limit", async () => {
    const recover = mock(async () => ({ delivery: "sent" as const }));
    const response = await makeEmailVerificationRecoveryHandler(
      dependencies({
        recover,
        isVercel: () => true,
        checkRateLimit: mock(async () => ({ rateLimited: true })),
      }),
    )(request({ email: "buyer@example.com" }));

    expect(response.status).toBe(429);
    expect(recover).not.toHaveBeenCalled();
  });

  test("accepts provider failure without exposing account state", async () => {
    const response = await makeEmailVerificationRecoveryHandler(
      dependencies({
        recover: async () => {
          throw new Error("provider unavailable");
        },
      }),
    )(request({ email: "buyer@example.com" }));

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ ok: true });
  });
});
