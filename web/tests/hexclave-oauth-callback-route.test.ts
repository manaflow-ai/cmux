import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";

const ORIGIN = "https://cmux.test";

const ENVIRONMENT_KEYS = [
  "NEXT_PUBLIC_STACK_PROJECT_ID",
  "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY",
  "STACK_API_BASE_URL",
] as const;
const previousEnvironment = Object.fromEntries(
  ENVIRONMENT_KEYS.map((key) => [key, process.env[key]]),
);
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "project-1";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "pck_test";
process.env.STACK_API_BASE_URL = "https://api.hexclave.test";

afterAll(() => {
  for (const key of ENVIRONMENT_KEYS) {
    const previous = previousEnvironment[key];
    if (previous === undefined) delete process.env[key];
    else process.env[key] = previous;
  }
});

const { GET } = await import("../app/handler/oauth-callback/route");
const { createOAuthHandoff, oauthHandoffCookieName } = await import(
  "../services/auth/hexclave/oauthState"
);

const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});

function callback(
  query: Record<string, string>,
  cookie?: string,
): NextRequest {
  const url = new URL(`${ORIGIN}/handler/oauth-callback`);
  for (const [key, value] of Object.entries(query)) {
    url.searchParams.set(key, value);
  }
  return new NextRequest(url, {
    headers: cookie ? { cookie } : {},
  });
}

async function handoffCookie(returnTo: string) {
  const handoff = await createOAuthHandoff(returnTo);
  const name = oauthHandoffCookieName(true);
  const value = encodeURIComponent(JSON.stringify({
    state: handoff.state,
    codeVerifier: handoff.codeVerifier,
    returnTo,
  }));
  return { handoff, cookie: `${name}=${value}`, name };
}

describe("OAuth callback", () => {
  test("exchanges the code and lands on the destination the start route chose", async () => {
    const { handoff, cookie } = await handoffCookie("/dashboard/billing");
    let sentBody = "";
    globalThis.fetch = (async (_input, init?: RequestInit) => {
      sentBody = String(init?.body);
      return new Response(JSON.stringify({
        access_token: "access-1",
        refresh_token: "refresh-1",
        is_new_user: false,
      }), { status: 200 });
    }) as typeof fetch;

    const response = await GET(
      callback({ code: "auth-code", state: handoff.state }, cookie),
    );

    expect(new URLSearchParams(sentBody).get("code_verifier"))
      .toBe(handoff.codeVerifier);
    expect(response.headers.get("location"))
      .toBe(`${ORIGIN}/dashboard/billing`);
    expect(response.cookies.get("hexclave-access")?.value)
      .toBe(JSON.stringify(["refresh-1", "access-1"]));
  });

  test("a forged error callback cannot cancel a live attempt", async () => {
    const { cookie, name } = await handoffCookie("/dashboard");

    const response = await GET(
      callback({ errorCode: "OAUTH_PROVIDER_ACCESS_DENIED", state: "forged" }, cookie),
    );

    // The visitor's real attempt is still usable in the other tab.
    expect(response.cookies.get(name)).toBeUndefined();
    expect(new URL(response.headers.get("location") ?? "").searchParams
      .get("error")).toBe("expiredCode");
  });

  test("a matching provider error clears the attempt and explains itself", async () => {
    const { handoff, cookie, name } = await handoffCookie("/dashboard");

    const response = await GET(callback({
      errorCode: "OAUTH_PROVIDER_ACCESS_DENIED",
      state: handoff.state,
    }, cookie));

    expect(response.cookies.get(name)?.value).toBe("");
    expect(new URL(response.headers.get("location") ?? "").searchParams
      .get("error")).toBe("oauthDenied");
  });

  test("a code with no handoff is never exchanged", async () => {
    let called = false;
    globalThis.fetch = (async () => {
      called = true;
      return new Response("{}", { status: 200 });
    }) as typeof fetch;

    const response = await GET(
      callback({ code: "someone-elses-code", state: "unknown" }),
    );

    expect(called).toBe(false);
    expect(new URL(response.headers.get("location") ?? "").searchParams
      .get("error")).toBe("expiredCode");
  });

  test("a network failure reaches the sign-in page, not a server error", async () => {
    const { handoff, cookie } = await handoffCookie("/dashboard");
    globalThis.fetch = (async () => {
      throw new TypeError("fetch failed");
    }) as typeof fetch;

    const response = await GET(
      callback({ code: "auth-code", state: handoff.state }, cookie),
    );

    expect(response.status).toBe(307);
    expect(new URL(response.headers.get("location") ?? "").searchParams
      .get("error")).toBe("unexpected");
  });

  test("a 2xx body that is not an object fails as a redirect", async () => {
    const { handoff, cookie } = await handoffCookie("/dashboard");
    globalThis.fetch = (async () =>
      new Response("null", { status: 200 })) as typeof fetch;

    const response = await GET(
      callback({ code: "auth-code", state: handoff.state }, cookie),
    );

    expect(response.status).toBe(307);
    expect(new URL(response.headers.get("location") ?? "").searchParams
      .get("error")).toBe("unexpected");
  });
});
