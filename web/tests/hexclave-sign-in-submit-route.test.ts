import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";

const ORIGIN = "https://cmux.test";

// Restored in afterAll: these assignments would otherwise follow the process
// into every later suite Bun runs in it.
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

const { POST } = await import("../app/handler/sign-in/submit/route");

type StubResponse = {
  readonly status?: number;
  readonly knownError?: string;
  readonly body: unknown;
};

const originalFetch = globalThis.fetch;
let calls: Array<{ url: string; body: unknown }> = [];

function stubHexclave(response: StubResponse) {
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({
      url: String(input),
      body: init?.body ? JSON.parse(String(init.body)) : null,
    });
    return new Response(JSON.stringify(response.body), {
      status: response.status ?? 200,
      headers: response.knownError
        ? { "x-hexclave-known-error": response.knownError }
        : {},
    });
  }) as typeof fetch;
}

function signInPost(fields: Record<string, string>): NextRequest {
  return new NextRequest(`${ORIGIN}/handler/sign-in/submit`, {
    method: "POST",
    headers: { origin: ORIGIN, "sec-fetch-site": "same-origin" },
    body: new URLSearchParams(fields),
  });
}

beforeEach(() => {
  calls = [];
});

afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("sign-in submit route", () => {
  test("password sign-in writes the session cookies the SDK reads", async () => {
    stubHexclave({
      body: { access_token: "access-1", refresh_token: "refresh-1" },
    });

    const response = await POST(signInPost({
      email: "someone@cmux.test",
      password: "correct horse battery",
      method: "password",
      after_auth_return_to: "/dashboard/billing",
    }));

    expect(response.status).toBe(307);
    expect(response.headers.get("location"))
      .toBe(`${ORIGIN}/dashboard/billing`);
    expect(response.cookies.get("hexclave-access")?.value)
      .toBe(JSON.stringify(["refresh-1", "access-1"]));
    const refresh = response.cookies.get(
      "__Host-hexclave-refresh-project-1--default",
    );
    expect(JSON.parse(refresh?.value ?? "{}").refresh_token).toBe("refresh-1");
  });

  test("a wrong password comes back as a localizable key, not upstream text", async () => {
    stubHexclave({
      knownError: "EMAIL_PASSWORD_MISMATCH",
      body: { code: "EMAIL_PASSWORD_MISMATCH", error: "Wrong e-mail or password." },
    });

    const response = await POST(signInPost({
      email: "someone@cmux.test",
      password: "nope",
      method: "password",
    }));

    const location = new URL(response.headers.get("location") ?? "");
    expect(location.pathname).toBe("/handler/sign-in");
    expect(location.searchParams.get("error")).toBe("invalidCredentials");
    expect(location.searchParams.get("method")).toBe("password");
    expect(response.headers.get("location")).not.toContain("Wrong e-mail");
  });

  test("an off-origin destination cannot survive the round trip", async () => {
    stubHexclave({
      body: { access_token: "access-1", refresh_token: "refresh-1" },
    });

    const response = await POST(signInPost({
      email: "someone@cmux.test",
      password: "correct horse battery",
      method: "password",
      after_auth_return_to: "https://evil.test/steal",
    }));

    expect(response.headers.get("location"))
      .toBe(`${ORIGIN}/handler/after-sign-in`);
  });

  test("the code path parks the nonce in an httpOnly cookie", async () => {
    stubHexclave({ body: { nonce: "nonce-1" } });

    const response = await POST(signInPost({
      email: "someone@cmux.test",
      method: "code",
    }));

    expect(calls[0]?.url)
      .toBe("https://api.hexclave.test/api/v1/auth/otp/send-sign-in-code");
    const location = new URL(response.headers.get("location") ?? "");
    expect(location.pathname).toBe("/handler/otp");
    expect(location.search).not.toContain("nonce-1");
    const nonce = response.cookies.get("__Host-cmux-otp-nonce");
    expect(nonce?.value).toBe("nonce-1");
    expect(nonce?.httpOnly).toBe(true);
  });

  test("coderouter never accepts a password even when one is posted", async () => {
    stubHexclave({ body: { nonce: "nonce-1" } });

    const request = new NextRequest(`${ORIGIN}/handler/sign-in/submit`, {
      method: "POST",
      headers: {
        origin: ORIGIN,
        "sec-fetch-site": "same-origin",
        host: "coderouter.dev",
      },
      body: new URLSearchParams({
        email: "someone@cmux.test",
        password: "correct horse battery",
        method: "password",
      }),
    });
    const response = await POST(request);

    expect(calls[0]?.url).toContain("/auth/otp/send-sign-in-code");
    expect(new URL(response.headers.get("location") ?? "").pathname)
      .toBe("/handler/otp");
  });

  test("a malformed address never reaches the auth API", async () => {
    stubHexclave({ body: {} });

    const response = await POST(signInPost({
      email: "not-an-address",
      method: "code",
    }));

    expect(calls).toHaveLength(0);
    expect(new URL(response.headers.get("location") ?? "").searchParams
      .get("error")).toBe("invalidEmail");
  });

  test("a cross-site submission is refused before any credential is read", async () => {
    stubHexclave({ body: {} });

    const request = new NextRequest(`${ORIGIN}/handler/sign-in/submit`, {
      method: "POST",
      headers: { origin: "https://evil.test", "sec-fetch-site": "cross-site" },
      body: new URLSearchParams({
        email: "someone@cmux.test",
        password: "correct horse battery",
        method: "password",
      }),
    });

    const response = await POST(request);
    // A navigation never gets a JSON literal: it lands on the localized
    // recovery page, and the reason stays in a header for the logs.
    expect(response.status).toBe(307);
    expect(new URL(response.headers.get("location") ?? "").pathname)
      .toBe("/handler/auth-error");
    expect(response.headers.get("x-cmux-auth-refused")).toBe("cross_origin");
    expect(calls).toHaveLength(0);
  });
});
