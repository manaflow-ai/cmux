import { describe, expect, mock, test } from "bun:test";

import { markPurchaseEmailVerified } from "../services/billing/stackVerification";
import { findOrCreateBillingUser } from "../services/billing/purchase";

describe("purchase email verification", () => {
  test("uses Stack's verified primary-email SDK field without rewriting spelling", async () => {
    const setPrimaryEmail = mock(async () => undefined);
    await markPurchaseEmailVerified(
      {
        id: "user-1",
        primaryEmail: "Billing.Fixture@Gmail.com",
        primaryEmailVerified: false,
        setPrimaryEmail,
      },
      "billingfixture@gmail.com",
    );

    expect(setPrimaryEmail).toHaveBeenCalledWith("Billing.Fixture@Gmail.com", {
      verified: true,
    });
  });

  test("uses the server update verified flag for older Stack user shapes", async () => {
    const update = mock(async () => undefined);
    await markPurchaseEmailVerified(
      {
        id: "user-2",
        primaryEmail: "buyer@example.com",
        primaryEmailVerified: false,
        update,
      },
      "buyer@example.com",
    );

    expect(update).toHaveBeenCalledWith({ primaryEmailVerified: true });
  });

  test("creates an unverified shell when an older SDK rejects the verification field", async () => {
    const update = mock(async () => undefined);
    const user = {
      id: "user-3",
      primaryEmail: "billingfixture@example.com",
      primaryEmailVerified: false,
      update,
    };
    const createUser = mock(async (rawOptions: unknown) => {
      const options = rawOptions as Record<string, unknown>;
      if ("primaryEmailVerified" in options) {
        throw new Error("unknown field primary_email_verified");
      }
      return user;
    });

    const result = await findOrCreateBillingUser(
      {
        listUsers: async () => [],
        createUser,
        getUser: async () => user,
      } as never,
      "billingfixture@example.com",
    );

    expect(result.id).toBe("user-3");
    expect(createUser).toHaveBeenCalledTimes(2);
    expect(createUser).toHaveBeenLastCalledWith({
      primaryEmail: "billingfixture@example.com",
      primaryEmailAuthEnabled: true,
    });
    expect(update).not.toHaveBeenCalled();
  });

  test("does not verify an existing unverified account from billing email alone", async () => {
    const update = mock(async () => undefined);
    const existing = {
      id: "existing-unverified",
      primaryEmail: "buyer@example.com",
      primaryEmailVerified: false,
      primaryEmailAuthEnabled: true,
      update,
    };

    const result = await findOrCreateBillingUser(
      {
        listUsers: async () => [existing],
        getUser: async () => existing,
      } as never,
      "buyer@example.com",
    );

    expect(result.id).toBe(existing.id);
    expect(update).not.toHaveBeenCalled();
  });

  test("leaves anonymous accounts for the combined promotion mutation", async () => {
    const update = mock(async () => undefined);
    const anonymous = {
      id: "anonymous-1",
      primaryEmail: "buyer@example.com",
      primaryEmailVerified: false,
      isAnonymous: true,
      update,
    };

    const result = await findOrCreateBillingUser(
      {
        listUsers: async () => [anonymous],
        getUser: async () => anonymous,
      } as never,
      "buyer@example.com",
    );

    expect(result.id).toBe("anonymous-1");
    expect(update).not.toHaveBeenCalled();
  });

  test("uses the centralized server API fallback when no verified SDK field exists", async () => {
    const previousFetch = globalThis.fetch;
    const fetchMock = mock(async (rawInput: unknown, rawInit?: unknown) => {
      const input = rawInput as RequestInfo | URL;
      const init = rawInit as RequestInit | undefined;
      const request = new Request(input, init);
      expect(request.method).toBe("PATCH");
      expect(request.url).toContain("/api/v1/users/user-4");
      expect(request.headers.get("x-hexclave-secret-server-key")).toBeTruthy();
      expect(request.headers.get("x-hexclave-access-type")).toBe("server");
      return new Response(null, { status: 200 });
    });
    globalThis.fetch = fetchMock as typeof globalThis.fetch;
    try {
      await markPurchaseEmailVerified(
        {
          id: "user-4",
          primaryEmail: "billingfixture@example.com",
          primaryEmailVerified: false,
        },
        "billingfixture@example.com",
      );
    } finally {
      globalThis.fetch = previousFetch;
    }
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("refuses to send the Stack server key to a non-HTTPS endpoint", async () => {
    const previousFetch = globalThis.fetch;
    const previousBaseURL = process.env.STACK_API_BASE_URL;
    const fetchMock = mock(async () => {
      throw new Error("fetch must not run");
    });
    process.env.STACK_API_BASE_URL = "http://stack.test";
    globalThis.fetch = fetchMock as typeof globalThis.fetch;
    try {
      await expect(
        markPurchaseEmailVerified(
          {
            id: "user-5",
            primaryEmail: "buyer@example.com",
            primaryEmailVerified: false,
          },
          "buyer@example.com",
        ),
      ).rejects.toThrow("must use HTTPS");
    } finally {
      globalThis.fetch = previousFetch;
      if (previousBaseURL === undefined) delete process.env.STACK_API_BASE_URL;
      else process.env.STACK_API_BASE_URL = previousBaseURL;
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
