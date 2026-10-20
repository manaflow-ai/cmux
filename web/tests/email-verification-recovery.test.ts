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

  test("continues duplicate-email pages until a usable channel is found", async () => {
    const sendVerificationEmail = mock(async () => undefined);
    const listUsers = mock(async (...args: unknown[]) => {
      const options = (args[0] ?? {}) as { cursor?: string };
      if (!options.cursor) {
        return Object.assign(
          [
            {
              primaryEmail: "buyer@example.com",
              listContactChannels: async () => [],
            },
          ],
          { nextCursor: "page-2" },
        );
      }
      return [
        {
          primaryEmail: "buyer@example.com",
          listContactChannels: async () => [
            {
              value: "buyer@example.com",
              isVerified: false,
              usedForAuth: true,
              sendVerificationEmail,
            },
          ],
        },
      ];
    }) as unknown as Parameters<
      typeof requestEmailVerificationRecovery
    >[1]["stackApp"]["listUsers"];

    const result = await Effect.runPromise(
      requestEmailVerificationRecovery(
        {
          email: "buyer@example.com",
          callbackURL: "https://cmux.test/handler/email-verification",
        },
        { stackApp: { listUsers } },
      ),
    );

    expect(result).toEqual({ delivery: "sent" });
    expect(sendVerificationEmail).toHaveBeenCalledTimes(1);
    expect(listUsers).toHaveBeenCalledWith({
      query: "buyer@example.com",
      cursor: "page-2",
      limit: 20,
      includeAnonymous: true,
      includeRestricted: true,
    });
  });

  test("queries literal Gmail spellings before declaring recovery unavailable", async () => {
    const sendVerificationEmail = mock(async () => undefined);
    const listContactChannels = mock(async () => [
      {
        value: "John.Doe@gmail.com",
        isVerified: false,
        usedForAuth: true,
        sendVerificationEmail,
      },
    ]);
    const listUsers = mock(async (...args: unknown[]) => {
      const { query } = args[0] as { query: string };
      return query === "john.doe@gmail.com"
        ? [{ primaryEmail: "John.Doe@gmail.com", listContactChannels }]
        : [];
    }) as unknown as Parameters<
      typeof requestEmailVerificationRecovery
    >[1]["stackApp"]["listUsers"];

    const result = await Effect.runPromise(
      requestEmailVerificationRecovery(
        {
          email: "john.doe@gmail.com",
          callbackURL: "https://cmux.com/handler/email-verification",
        },
        { stackApp: { listUsers } },
      ),
    );

    expect(listUsers).toHaveBeenCalledWith({
      query: "john.doe@gmail.com",
      limit: 20,
      includeAnonymous: true,
      includeRestricted: true,
    });
    expect(sendVerificationEmail).toHaveBeenCalledWith({
      callbackUrl: "https://cmux.com/handler/email-verification",
    });
    expect(result).toEqual({ delivery: "sent" });
  });

  test("finds a differently dotted Gmail account with the paginated fallback", async () => {
    const sendVerificationEmail = mock(async () => undefined);
    const listContactChannels = mock(async () => [
      {
        value: "John.Doe@gmail.com",
        isVerified: false,
        usedForAuth: true,
        sendVerificationEmail,
      },
    ]);
    const listUsers = mock(async (...args: unknown[]) => {
      const options = (args[0] ?? {}) as { query?: string };
      return options.query
        ? []
        : [{ primaryEmail: "John.Doe@gmail.com", listContactChannels }];
    }) as unknown as Parameters<
      typeof requestEmailVerificationRecovery
    >[1]["stackApp"]["listUsers"];

    const result = await Effect.runPromise(
      requestEmailVerificationRecovery(
        {
          email: "johndoe@gmail.com",
          callbackURL: "https://cmux.test/handler/email-verification",
        },
        { stackApp: { listUsers } },
      ),
    );

    expect(result).toEqual({ delivery: "sent" });
    expect(sendVerificationEmail).toHaveBeenCalledWith({
      callbackUrl: "https://cmux.test/handler/email-verification",
    });
    expect(listUsers).toHaveBeenCalledWith({
      limit: 100,
      includeAnonymous: true,
      includeRestricted: true,
    });
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
