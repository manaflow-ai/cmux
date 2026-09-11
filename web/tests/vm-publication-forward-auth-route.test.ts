import { describe, expect, test } from "bun:test";

import {
  enforcePublicationSignInRateLimit,
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
const target = {
  publication: { id: "publication-1", hostname: "preview.example.com" },
} as unknown as Parameters<ForwardAuthHandlerDependencies["begin"]>[0]["target"];
// What Vercel actually hands the function: its own host, not the publication's.
const vercelForwardedHost = "cmux.com";

function request(
  overrides: Record<string, string> = {},
): Request {
  return new Request("https://cmux.com/api/freestyle/forward-auth", {
    headers: {
      authorization: `Bearer ${serviceSecret}`,
      "x-forwarded-proto": "https",
      "x-forwarded-host": vercelForwardedHost,
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
    resolve: async () => target,
    evaluate: async () => ({ kind: "allow" }),
    begin: async () => {
      throw new Error("unexpected transaction");
    },
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
        evaluate: async () => {
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
      { "x-freestyle-tls-rule-id": "rule/id" },
      { "x-freestyle-tls-rule-id": "" },
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
        evaluate: async (input) => {
          captured = input as unknown as Record<string, unknown>;
          return { kind: "allow" };
        },
      }),
    );

    expect(result.status).toBe(204);
    expect(captured).toEqual({
      providerTlsRuleId: "tls-rule-1",
      method: "HEAD",
      sessionToken: session,
    });
  });

  test("identifies the publication by TLS rule id, never by x-forwarded-host", async () => {
    // Vercel overwrites x-forwarded-host with the function's own host before the
    // route runs, so a hostname-keyed lookup 404s every protected publication.
    // The route must not read that header at all: any value, or none, is fine.
    for (const forwardedHost of [vercelForwardedHost, "!!!not a host!!!", undefined]) {
      const headers: Record<string, string> = forwardedHost === undefined
        ? {}
        : { "x-forwarded-host": forwardedHost };
      const req = request(headers);
      if (forwardedHost === undefined) req.headers.delete("x-forwarded-host");
      const limited: string[] = [];
      const result = await handleForwardAuthRequest(
        req,
        dependencies({
          evaluate: async () => ({ kind: "sign_in_required", target }),
          rateLimit: async ({ hostname }) => {
            limited.push(hostname);
            return null;
          },
          begin: async () => ({
            location: "https://cmux.com/cloud/access?transaction=one&state=two",
            transactionCookie: "",
          }),
        }),
      );
      expect(result.status).toBe(302);
      expect(limited).toEqual(["preview.example.com"]);
    }
  });

  test("relays a cross-origin authorization redirect with a protected transaction cookie", async () => {
    const transactionCookie = publicationTransactionCookieValue(
      randomPublicationToken(),
      randomPublicationToken(),
    );
    const location = "https://cmux.com/cloud/access?transaction=one&state=two";
    let begun: Record<string, unknown> | null = null;
    const result = await handleForwardAuthRequest(
      request(),
      dependencies({
        evaluate: async () => ({ kind: "sign_in_required", target }),
        begin: async (input) => {
          begun = input as unknown as Record<string, unknown>;
          return { location, transactionCookie };
        },
      }),
    );

    expect(result.status).toBe(302);
    expect(begun).toMatchObject({
      target,
      returnPath: "/editor?file=readme",
      authPageOrigin: "https://cmux.com",
    });
    expect(result.headers.get("location")).toBe(location);
    const cookie = result.headers.get("set-cookie") ?? "";
    expect(cookie).toContain(`${PUBLICATION_TRANSACTION_COOKIE}=${transactionCookie}`);
    expect(cookie).toContain("Secure");
    expect(cookie).toContain("HttpOnly");
    expect(cookie).toContain("SameSite=Lax");
    expect(cookie.toLowerCase()).not.toContain("domain=");
  });

  test("does not redirect a non-idempotent request or mint it a transaction cookie", async () => {
    const result = await handleForwardAuthRequest(
      request({ "x-forwarded-method": "POST" }),
      dependencies({ evaluate: async () => ({ kind: "unauthorized" }) }),
    );

    expect(result.status).toBe(401);
    expect(result.headers.get("location")).toBeNull();
    expect(result.headers.get("set-cookie")).toBeNull();
    expect(result.headers.get("cache-control")).toBe("no-store");
    expect(await result.text()).toBe("");
  });

  test("uses only the configured sign-in origin and fails closed without one", async () => {
    const foreignRequest = (overrides: Record<string, string> = {}) =>
      new Request("https://attacker.example/api/freestyle/forward-auth", {
        headers: request(overrides).headers,
      });

    for (const authPageOrigin of [undefined, "", "http://cmux.com", "https://cmux.com/cloud"]) {
      let authorized = false;
      const result = await handleForwardAuthRequest(
        foreignRequest(),
        dependencies({
          authPageOrigin,
          evaluate: async () => {
            authorized = true;
            return { kind: "allow" };
          },
        }),
      );
      expect(result.status).toBe(503);
      expect(result.headers.get("cache-control")).toBe("no-store");
      expect(authorized).toBe(false);
    }

    let captured: { authPageOrigin: string } | null = null;
    const result = await handleForwardAuthRequest(
      foreignRequest(),
      dependencies({
        authPageOrigin: "https://cmux.com/",
        evaluate: async () => ({ kind: "sign_in_required", target }),
        begin: async (input) => {
          captured = { authPageOrigin: input.authPageOrigin };
          return {
            location: "https://cmux.com/cloud/access?transaction=one&state=two",
            transactionCookie: "",
          };
        },
      }),
    );
    expect(result.status).toBe(302);
    expect(captured).toEqual({ authPageOrigin: "https://cmux.com" });
  });

  test("rate limits only the requests that would mint a sign-in transaction", async () => {
    const events: string[] = [];
    const limited = new Response(JSON.stringify({ error: "rate_limited" }), { status: 429 });
    const deps = (evaluation: Awaited<ReturnType<ForwardAuthHandlerDependencies["evaluate"]>>) =>
      dependencies({
        evaluate: async () => evaluation,
        rateLimit: async ({ hostname }) => {
          events.push(`limit:${hostname}`);
          return limited;
        },
        begin: async () => {
          events.push("begin");
          return { location: "https://cmux.com/cloud/access", transactionCookie: "" };
        },
      });

    const allowed = await handleForwardAuthRequest(request(), deps({ kind: "allow" }));
    expect(allowed.status).toBe(204);
    const refused = await handleForwardAuthRequest(
      request(),
      deps({ kind: "sign_in_required", target }),
    );
    expect(refused.status).toBe(429);
    expect(events).toEqual(["limit:preview.example.com"]);
  });

  test("keys the sign-in rate limit by the relayed browser address and hostname", async () => {
    const seen: Array<{ id: string; key: string | undefined }> = [];
    const check = async (id: string, options: { rateLimitKey?: string }) => {
      seen.push({ id, key: options.rateLimitKey });
      return { rateLimited: id === "rule-limited" };
    };
    const forwarded = new Request("https://cmux.com/api/freestyle/forward-auth", {
      headers: { "x-forwarded-for": " 203.0.113.9 , 198.51.100.2" },
    });

    expect(await enforcePublicationSignInRateLimit({
      request: forwarded,
      hostname: "preview.example.com",
      ruleId: "rule-open",
      check,
      isVercel: true,
    })).toBeNull();
    const refused = await enforcePublicationSignInRateLimit({
      request: forwarded,
      hostname: "preview.example.com",
      ruleId: "rule-limited",
      check,
      isVercel: true,
    });
    expect(refused?.status).toBe(429);
    expect(seen).toEqual([
      { id: "rule-open", key: "publication-sign-in:preview.example.com:203.0.113.9" },
      { id: "rule-limited", key: "publication-sign-in:preview.example.com:203.0.113.9" },
    ]);

    // No rule configured, or not on Vercel: nothing is checked.
    expect(await enforcePublicationSignInRateLimit({
      request: forwarded,
      hostname: "preview.example.com",
      ruleId: undefined,
      check,
      isVercel: true,
    })).toBeNull();
    expect(await enforcePublicationSignInRateLimit({
      request: forwarded,
      hostname: "preview.example.com",
      ruleId: "rule-limited",
      check,
      isVercel: false,
    })).toBeNull();
    expect(seen).toHaveLength(2);
  });

  test("only completes the callback for a browser navigation", async () => {
    let completed = false;
    const result = await handleForwardAuthRequest(
      request({
        "x-forwarded-method": "POST",
        "x-forwarded-uri": "/_cmux/auth/callback?code=abc&state=def",
        cookie: `${PUBLICATION_TRANSACTION_COOKIE}=${publicationTransactionCookieValue(
          randomPublicationToken(),
          randomPublicationToken(),
        )}`,
      }),
      dependencies({
        complete: async () => {
          completed = true;
          return { kind: "invalid" };
        },
      }),
    );

    expect(result.status).toBe(400);
    expect(completed).toBe(false);
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
    // Bound to the resolved publication's hostname, not to x-forwarded-host.
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

  test("refuses the callback when no active publication owns the TLS rule", async () => {
    let completed = false;
    const result = await handleForwardAuthRequest(
      request({
        cookie: `${PUBLICATION_TRANSACTION_COOKIE}=${publicationTransactionCookieValue(
          randomPublicationToken(),
          randomPublicationToken(),
        )}`,
        "x-forwarded-uri": "/_cmux/auth/callback?code=abc&state=def",
      }),
      dependencies({
        resolve: async () => null,
        complete: async () => {
          completed = true;
          return { kind: "invalid" };
        },
      }),
    );

    expect(result.status).toBe(404);
    expect(completed).toBe(false);
  });

  test("fails closed when policy infrastructure fails", async () => {
    const originalError = console.error;
    console.error = () => {};
    try {
      const result = await handleForwardAuthRequest(
        request(),
        dependencies({
          evaluate: async () => {
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
