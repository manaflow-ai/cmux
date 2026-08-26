import { describe, expect, mock, test } from "bun:test";
import * as Effect from "effect/Effect";

import {
  EmailVerificationRecoveryUnavailable,
  requestEmailVerificationRecovery,
} from "../services/auth/emailVerificationRecovery";

describe("email verification recovery", () => {
  test("sends Stack verification to the exact unverified auth channel", async () => {
    const sendVerificationEmail = mock(async () => undefined);
    const listContactChannels = mock(async () => [
      {
        value: "Buyer@Example.com",
        isVerified: false,
        usedForAuth: true,
        sendVerificationEmail,
      },
    ]);
    const listUsers = mock(async () => [
      {
        primaryEmail: "Buyer@Example.com",
        listContactChannels,
      },
    ]);

    const result = await Effect.runPromise(
      requestEmailVerificationRecovery(
        {
          email: " buyer@example.com ",
          callbackURL: "https://cmux.com/handler/email-verification",
        },
        { stackApp: { listUsers } },
      ),
    );

    expect(listUsers).toHaveBeenCalledWith({
      query: "buyer@example.com",
      limit: 20,
      includeAnonymous: true,
      includeRestricted: true,
    });
    expect(sendVerificationEmail).toHaveBeenCalledWith({
      callbackUrl: "https://cmux.com/handler/email-verification",
    });
    expect(result).toEqual({ delivery: "sent" });
  });

  test("returns the same accepted result when no recoverable channel exists", async () => {
    const sendVerificationEmail = mock(async () => undefined);
    const listUsers = mock(async () => [
      {
        primaryEmail: "not-buyer@example.com",
        listContactChannels: async () => [
          {
            value: "not-buyer@example.com",
            isVerified: false,
            usedForAuth: true,
            sendVerificationEmail,
          },
        ],
      },
    ]);

    const result = await Effect.runPromise(
      requestEmailVerificationRecovery(
        {
          email: "buyer@example.com",
          callbackURL: "https://cmux.com/handler/email-verification",
        },
        { stackApp: { listUsers } },
      ),
    );

    expect(sendVerificationEmail).not.toHaveBeenCalled();
    expect(result).toEqual({ delivery: "accepted" });
  });

  test("maps Stack failures to a typed unavailable error", async () => {
    const program = requestEmailVerificationRecovery(
      {
        email: "buyer@example.com",
        callbackURL: "https://cmux.com/handler/email-verification",
      },
      {
        stackApp: {
          listUsers: async () => {
            throw new Error("provider unavailable");
          },
        },
      },
    );

    const result = await Effect.runPromise(Effect.either(program));
    expect(result._tag).toBe("Left");
    if (result._tag === "Left") {
      expect(result.left).toBeInstanceOf(EmailVerificationRecoveryUnavailable);
    }
  });
});
