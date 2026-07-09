import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { NextRequest, type NextFetchEvent } from "next/server";

import {
  decodeAccessTokenPayload,
  extractStackAccessToken,
  type StackSessionVerifyFetch,
} from "../app/lib/stack-session-edge";

const originalProjectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
const originalPublishableKey = process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;

let fetchCalls = 0;
let defaultFetchCalls = 0;
let lastFetchInit: RequestInit | undefined;
let lastDefaultFetchInit: RequestInit | undefined;

const okVerifyFetch: StackSessionVerifyFetch = async (_input, init) => {
  fetchCalls += 1;
  lastFetchInit = init;
  return Response.json({ is_anonymous: false, is_restricted: false });
};

const originalFetch = globalThis.fetch;
const defaultVerifyFetch: typeof fetch = async (_input, init) => {
  defaultFetchCalls += 1;
  lastDefaultFetchInit = init;
  return Response.json({ is_anonymous: false, is_restricted: false });
};

globalThis.fetch = defaultVerifyFetch;
const { default: middleware, buildMiddleware } = await import("../proxy");

afterAll(() => {
  restoreEnv("NEXT_PUBLIC_STACK_PROJECT_ID", originalProjectId);
  restoreEnv("NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY", originalPublishableKey);
  globalThis.fetch = originalFetch;
});

beforeEach(() => {
  process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "project-test";
  process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "publishable-test";
  fetchCalls = 0;
  defaultFetchCalls = 0;
  lastFetchInit = undefined;
  lastDefaultFetchInit = undefined;
});

describe("proxy signed-in forwarding", () => {
  const middlewareWithOkFetch = buildMiddleware(okVerifyFetch);

  test("default export ignores the production NextFetchEvent argument and still redirects", async () => {
    const accessToken = stackJwt({ is_anonymous: false, exp: futureExp() });
    const productionMiddleware = middleware as unknown as (
      request: NextRequest,
      event: NextFetchEvent,
    ) => Promise<Response>;

    const response = await productionMiddleware(
      handlerRequest("/handler/sign-in", nativeAfterSignInTarget(), accessCookie(accessToken)),
      nextFetchEvent(),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")?.endsWith(nativeAfterSignInTarget())).toBe(true);
    expect(defaultFetchCalls).toBe(1);
    expect(headerValue(lastDefaultFetchInit, "x-stack-access-token")).toBe(accessToken);
  });

  test("redirects signed-in handler sign-in requests before rendering", async () => {
    const accessToken = stackJwt({ is_anonymous: false, exp: futureExp() });
    const response = await middlewareWithOkFetch(
      handlerRequest("/handler/sign-in", nativeAfterSignInTarget(), accessCookie(accessToken)),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")?.endsWith(nativeAfterSignInTarget())).toBe(true);
    expect(fetchCalls).toBe(1);
    expect(headerValue(lastFetchInit, "x-stack-access-token")).toBe(accessToken);
  });

  test("redirects signed-in handler sign-up requests before rendering", async () => {
    const response = await middlewareWithOkFetch(
      handlerRequest(
        "/handler/sign-up",
        nativeAfterSignInTarget(),
        accessCookie(stackJwt({ is_anonymous: false, exp: futureExp() })),
      ),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")?.endsWith(nativeAfterSignInTarget())).toBe(true);
    expect(fetchCalls).toBe(1);
  });

  test("does not redirect anonymous JWT sessions", async () => {
    const response = await middlewareWithOkFetch(
      handlerRequest(
        "/handler/sign-in",
        nativeAfterSignInTarget(),
        accessCookie(stackJwt({ is_anonymous: true, exp: futureExp() })),
      ),
    );

    expectNoRedirect(response);
    expect(fetchCalls).toBe(0);
  });

  test("does not redirect without a usable unexpired access cookie", async () => {
    for (const cookie of [
      undefined,
      "hexclave-access=garbage",
      accessCookie(stackJwt({ is_anonymous: false, exp: pastExp() })),
    ]) {
      fetchCalls = 0;

      const response = await middlewareWithOkFetch(
        handlerRequest("/handler/sign-in", nativeAfterSignInTarget(), cookie),
      );

      expectNoRedirect(response);
      expect(fetchCalls).toBe(0);
    }
  });

  test("does not redirect when Stack verification fails", async () => {
    const failingVerifyFetch: StackSessionVerifyFetch = async () => {
      fetchCalls += 1;
      return new Response(null, { status: 401 });
    };

    const response = await buildMiddleware(failingVerifyFetch)(
      handlerRequest(
        "/handler/sign-in",
        nativeAfterSignInTarget(),
        accessCookie(stackJwt({ is_anonymous: false, exp: futureExp() })),
      ),
    );

    expectNoRedirect(response);
    expect(fetchCalls).toBe(1);
  });

  test("does not redirect restricted users reported by Stack verification", async () => {
    const restrictedVerifyFetch: StackSessionVerifyFetch = async () => {
      fetchCalls += 1;
      return Response.json({ is_anonymous: false, is_restricted: true });
    };

    const response = await buildMiddleware(restrictedVerifyFetch)(
      handlerRequest(
        "/handler/sign-in",
        nativeAfterSignInTarget(),
        accessCookie(stackJwt({ is_anonymous: false, exp: futureExp() })),
      ),
    );

    expectNoRedirect(response);
    expect(fetchCalls).toBe(1);
  });

  test("does not verify or redirect foreign-host after_auth_return_to targets", async () => {
    const response = await middlewareWithOkFetch(
      handlerRequest(
        "/handler/sign-in",
        `https://evil.example${nativeAfterSignInTarget()}`,
        accessCookie(stackJwt({ is_anonymous: false, exp: futureExp() })),
      ),
    );

    expectNoRedirect(response);
    expect(fetchCalls).toBe(0);
  });

  test("leaves other handler paths untouched if invoked directly", async () => {
    const response = await middlewareWithOkFetch(
      new NextRequest("https://cmux.test/handler/oauth-callback", {
        headers: { host: "cmux.test" },
      }),
    );

    expectNoRedirect(response);
    expect(fetchCalls).toBe(0);
  });

  test("keeps normal page proxy behavior active", async () => {
    const response = await middlewareWithOkFetch(
      new NextRequest("https://cmux.test/", {
        headers: { host: "cmux.test" },
      }),
    );

    expect(response).toBeInstanceOf(Response);
  });
});

describe("edge Stack session helpers", () => {
  test("extracts access tokens from encoded Stack access cookie arrays", () => {
    const accessToken = stackJwt({ is_anonymous: false, exp: futureExp() });

    expect(
      extractStackAccessToken({
        getAll: () => [
          {
            name: "__Secure-hexclave-access--branch",
            value: encodeURIComponent(JSON.stringify(["refresh-token", accessToken])),
          },
        ],
      }),
    ).toBe(accessToken);
  });

  test("extracts raw access-token cookies", () => {
    const accessToken = stackJwt({ is_anonymous: false, exp: futureExp() });

    expect(
      extractStackAccessToken({
        getAll: () => [{ name: "stack-access", value: accessToken }],
      }),
    ).toBe(accessToken);
  });

  test("decodes JWT payloads with base64url encoding", () => {
    const payload = decodeAccessTokenPayload(
      stackJwt({ is_anonymous: false, exp: 1_800_000_000 }),
    );

    expect(payload).toEqual({ is_anonymous: false, exp: 1_800_000_000 });
  });
});

function handlerRequest(pathname: string, afterAuthReturnTo: string, cookie?: string): NextRequest {
  const url = new URL(`https://cmux.test${pathname}`);
  url.searchParams.set("after_auth_return_to", afterAuthReturnTo);

  return new NextRequest(url, {
    headers: {
      host: "cmux.test",
      ...(cookie ? { cookie } : {}),
    },
  });
}

function nativeAfterSignInTarget(): string {
  return "/handler/after-sign-in?native_app_return_to=cmux%3A%2F%2Fauth-callback%3Fcmux_auth_state%3Dabc";
}

function accessCookie(accessToken: string): string {
  return `hexclave-access=${encodeURIComponent(JSON.stringify(["refresh-token", accessToken]))}`;
}

function stackJwt(payload: Record<string, unknown>): string {
  return [
    base64UrlEncode(JSON.stringify({ alg: "none", typ: "JWT" })),
    base64UrlEncode(JSON.stringify(payload)),
    "signature",
  ].join(".");
}

function base64UrlEncode(value: string): string {
  return btoa(value).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function futureExp(): number {
  return Math.floor(Date.now() / 1000) + 3600;
}

function pastExp(): number {
  return Math.floor(Date.now() / 1000) - 3600;
}

function expectNoRedirect(response: Response) {
  expect(response.status).toBe(200);
  expect(response.headers.get("location")).toBeNull();
}

function headerValue(init: RequestInit | undefined, name: string): string | null {
  if (!init?.headers) return null;
  return new Headers(init.headers).get(name);
}

function nextFetchEvent(): NextFetchEvent {
  return {
    waitUntil: () => undefined,
  } as unknown as NextFetchEvent;
}

function restoreEnv(name: string, value: string | undefined) {
  if (value === undefined) {
    delete process.env[name];
  } else {
    process.env[name] = value;
  }
}
