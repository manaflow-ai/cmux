import { describe, expect, test } from "bun:test";

import {
  handleForwardAuthRequest,
  type ForwardAuthHandlerDependencies,
} from "../app/api/freestyle/forward-auth/route";
import {
  PUBLICATION_SESSION_COOKIE,
  PUBLICATION_TRANSACTION_COOKIE,
  publicationTransactionCookieValue,
  randomPublicationToken,
} from "../services/vm-publications/security";

const serviceSecret = "publication-forward-auth-test-secret";

function request(
  overrides: Record<string, string> = {},
): Request {
  return new Request("https://cmux.com/api/freestyle/forward-auth", {
    headers: {
      authorization: `Bearer ${serviceSecret}`,
      "x-forwarded-proto": "https",
      "x-forwarded-host": "preview.example.com",
      "x-forwarded-method": "GET",
      "x-forwarded-uri": "/editor?file=readme",
      "x-freestyle-tls-rule-id": "tls-rule-1",
      ...overrides,
    },
  });
}

function dependencies(
  overrides: Partial<ForwardAuthHandlerDependencies> = {},
): ForwardAuthHandlerDependencies {
  return {
    serviceSecret,
    authPageOrigin: "https://cmux.com",
    authorize: async () => ({ kind: "allow" }),
    complete: async () => ({ kind: "invalid" }),
    ...overrides,
  };
}

describe("Freestyle publication forward-auth HTTP contract", () => {
  test("rejects the caller before authorization when the shared secret is wrong", async () => {
    let called = false;
    const result = await handleForwardAuthRequest(
      request({ authorization: "Bearer wrong-secret" }),
      dependencies({
        authorize: async () => {
          called = true;
          return { kind: "allow" };
        },
      }),
    );

    expect(result.status).toBe(401);
    expect(result.headers.get("cache-control")).toBe("no-store");
    expect(called).toBe(false);
  });

  test("requires complete trusted HTTPS request metadata", async () => {
    const malformedHeaders: readonly Record<string, string>[] = [
      { "x-forwarded-proto": "http" },
      { "x-forwarded-host": "localhost" },
      { "x-freestyle-tls-rule-id": "rule/id" },
      { "x-forwarded-uri": "https://attacker.example/" },
    ];
    for (const headers of malformedHeaders) {
      const result = await handleForwardAuthRequest(
        request(headers),
        dependencies(),
      );
      expect(result.status).toBe(400);
    }
  });

  test("passes exact publication metadata and session material to policy", async () => {
    let captured: Record<string, unknown> | null = null;
    const session = randomPublicationToken();
    const result = await handleForwardAuthRequest(
      request({
        cookie: `${PUBLICATION_SESSION_COOKIE}=${session}`,
        "x-forwarded-method": "HEAD",
      }),
      dependencies({
        authorize: async (input) => {
          captured = input as unknown as Record<string, unknown>;
          return { kind: "allow" };
        },
      }),
    );

    expect(result.status).toBe(204);
    expect(captured).toMatchObject({
      hostname: "preview.example.com",
      providerTlsRuleId: "tls-rule-1",
      method: "HEAD",
      returnPath: "/editor?file=readme",
      sessionToken: session,
      authPageOrigin: "https://cmux.com",
    });
  });

  test("relays a cross-origin authorization redirect with a protected transaction cookie", async () => {
    const transactionCookie = publicationTransactionCookieValue(
      randomPublicationToken(),
      randomPublicationToken(),
    );
    const location = "https://cmux.com/cloud/access?transaction=one&state=two";
    const result = await handleForwardAuthRequest(
      request(),
      dependencies({
        authorize: async () => ({
          kind: "redirect",
          location,
          transactionCookie,
        }),
      }),
    );

    expect(result.status).toBe(302);
    expect(result.headers.get("location")).toBe(location);
    const cookie = result.headers.get("set-cookie") ?? "";
    expect(cookie).toContain(`${PUBLICATION_TRANSACTION_COOKIE}=${transactionCookie}`);
    expect(cookie).toContain("Secure");
    expect(cookie).toContain("HttpOnly");
    expect(cookie).toContain("SameSite=Lax");
    expect(cookie.toLowerCase()).not.toContain("domain=");
  });

  test("does not redirect a non-idempotent request", async () => {
    const location = "https://cmux.com/cloud/access?transaction=one&state=two";
    const result = await handleForwardAuthRequest(
      request({ "x-forwarded-method": "POST" }),
      dependencies({
        authorize: async () => ({
          kind: "unauthorized",
          location,
          transactionCookie: publicationTransactionCookieValue(
            randomPublicationToken(),
            randomPublicationToken(),
          ),
        }),
      }),
    );

    expect(result.status).toBe(401);
    expect(result.headers.get("location")).toBe(location);
    expect(await result.text()).toBe("");
  });

  test("exchanges the host-bound callback once and rotates into a session cookie", async () => {
    const transaction = randomPublicationToken();
    const verifier = randomPublicationToken();
    const code = randomPublicationToken();
    const state = randomPublicationToken();
    const session = randomPublicationToken();
    let captured: Record<string, unknown> | null = null;
    const result = await handleForwardAuthRequest(
      request({
        cookie: `${PUBLICATION_TRANSACTION_COOKIE}=${publicationTransactionCookieValue(transaction, verifier)}`,
        "x-forwarded-uri": `/_cmux/auth/callback?code=${code}&state=${state}`,
      }),
      dependencies({
        complete: async (input) => {
          captured = input as unknown as Record<string, unknown>;
          return { kind: "complete", sessionToken: session, returnPath: "/editor" };
        },
      }),
    );

    expect(result.status).toBe(302);
    expect(result.headers.get("location")).toBe("/editor");
    expect(captured).toEqual({
      hostname: "preview.example.com",
      code,
      state,
      transaction,
      verifier,
    });
    const cookies = result.headers.getSetCookie();
    expect(cookies).toHaveLength(2);
    expect(cookies[0]).toContain(`${PUBLICATION_SESSION_COOKIE}=${session}`);
    expect(cookies[1]).toContain(`${PUBLICATION_TRANSACTION_COOKIE}=;`);
    expect(cookies[1]).toContain("Max-Age=0");
  });

  test("fails closed when policy infrastructure fails", async () => {
    const originalError = console.error;
    console.error = () => {};
    try {
      const result = await handleForwardAuthRequest(
        request(),
        dependencies({
          authorize: async () => {
            throw new Error("database unavailable");
          },
        }),
      );
      expect(result.status).toBe(503);
    } finally {
      console.error = originalError;
    }
  });
});
