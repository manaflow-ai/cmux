import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

process.env.SKIP_ENV_VALIDATION = "1";
process.env.VERCEL = "1";
process.env.CMUX_APP_SESSION_HANDOFF_RATE_LIMIT_ID = "app-session-handoff";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "12345678-1234-4123-8123-123456789abc";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "test-publishable-key";
process.env.STACK_SECRET_SERVER_KEY = "test-secret-key";

const getCurrentSessionTokens = mock(async () => ({
  refreshToken: "validated-refresh",
  accessToken: "validated-access",
}));
const getUser = mock(async () => ({
  currentSession: { getTokens: getCurrentSessionTokens },
}));
let durableRateLimited = false;
const checkRateLimit = mock(async () => ({
  rateLimited: durableRateLimited,
  error: null as string | null,
}));

mock.module("@vercel/firewall", () => ({ checkRateLimit }));

const { makeAppSessionHandoffHandler } = await import(
  "../app/handler/app-session-handoff/route"
);

const POST = makeAppSessionHandoffHandler({
  projectId: "12345678-1234-4123-8123-123456789abc",
  stackServerApp: { getUser },
  now: () => 1_721_955_600_000,
  rateLimitId: "app-session-handoff",
});

function handoffRequest(
  body: Record<string, string>,
  headers: Record<string, string> = {},
): NextRequest {
  return new NextRequest("https://cmux.test/handler/app-session-handoff", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "x-cmux-app-session-handoff": "1",
      "user-agent": "bun-test",
      "x-forwarded-for": "203.0.113.10",
      ...headers,
    },
    body: new URLSearchParams(body),
  });
}

describe("app session handoff", () => {
  beforeEach(() => {
    getUser.mockClear();
    getCurrentSessionTokens.mockClear();
    checkRateLimit.mockClear();
    getUser.mockResolvedValue({
      currentSession: { getTokens: getCurrentSessionTokens },
    });
    durableRateLimited = false;
    getCurrentSessionTokens.mockResolvedValue({
      refreshToken: "validated-refresh",
      accessToken: "validated-access",
    });
  });

  test("authenticates with the refresh token, reuses that session, and redirects", async () => {
    const response = await POST(handoffRequest({
      refresh_token: "native-refresh",
      access_token: "native-access",
      after: "/dashboard/testflight?plan=pro#join",
    }));

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/testflight?plan=pro#join",
    );
    expect(response.headers.get("location")).not.toContain("native-refresh");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    expect(getUser).toHaveBeenCalledWith({
      tokenStore: { refreshToken: "native-refresh" },
    });
    expect(getCurrentSessionTokens).toHaveBeenCalledTimes(1);

    const setCookie = response.headers.get("set-cookie") ?? "";
    expect(setCookie).toContain("hexclave-access=");
    expect(setCookie).toContain(
      encodeURIComponent(JSON.stringify(["validated-refresh", "validated-access"])),
    );
    expect(setCookie).toContain(
      "__Host-hexclave-refresh-12345678-1234-4123-8123-123456789abc--default=",
    );
    expect(setCookie).toContain(
      encodeURIComponent(JSON.stringify({
        refresh_token: "validated-refresh",
        updated_at_millis: 1_721_955_600_000,
      })),
    );
    expect(setCookie.toLowerCase()).not.toContain("httponly");
    expect(setCookie).not.toContain("native-refresh");
    expect(setCookie).not.toContain("native-access");
  });

  test("returns cookies without navigating when the native app requests an exchange", async () => {
    const response = await POST(handoffRequest({
      refresh_token: "native-refresh",
      access_token: "native-access",
      after: "/dashboard/testflight?plan=pro#join",
    }, {
      "x-cmux-app-session-response": "cookies",
    }));

    expect(response.status).toBe(204);
    expect(response.headers.get("location")).toBeNull();
    expect(response.headers.get("x-cmux-app-session-handoff")).toBe("ready");
    expect(response.headers.get("set-cookie")).toContain("hexclave-access=");
  });

  test("fails a native cookie exchange closed instead of opening web sign-in", async () => {
    getUser.mockResolvedValue(null);

    const response = await POST(handoffRequest({
      refresh_token: "bad-refresh",
      after: "/dashboard/testflight",
    }, {
      "x-cmux-app-session-response": "cookies",
    }));

    expect(response.status).toBe(401);
    expect(response.headers.get("location")).toBeNull();
    expect(response.headers.get("set-cookie")).toBeNull();
  });

  test("accepts refresh-only handoff", async () => {
    const response = await POST(handoffRequest({
      refresh_token: "native-refresh",
      after: "/dashboard/testflight",
    }));

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/testflight",
    );
    expect(getUser).toHaveBeenCalledWith({
      tokenStore: { refreshToken: "native-refresh" },
    });
  });

  test("does not set cookies when Stack rejects the native session", async () => {
    getUser.mockResolvedValue(null);

    const response = await POST(handoffRequest({
      refresh_token: "bad-refresh",
      after: "/dashboard/testflight",
    }));

    const location = new URL(response.headers.get("location")!);
    expect(location.pathname).toBe("/handler/sign-in");
    expect(location.searchParams.get("after_auth_return_to")).toBe(
      "/dashboard/testflight",
    );
    expect(response.status).toBe(303);
    expect(response.headers.get("set-cookie")).toBeNull();
  });

  test("rejects off-origin and recursive destinations before reading tokens", async () => {
    const offOrigin = await POST(handoffRequest({
      refresh_token: "native-refresh",
      after: "https://evil.test/dashboard",
    }));
    const recursive = await POST(handoffRequest({
      refresh_token: "native-refresh",
      after: "/handler/app-session-handoff?after=%2Fdashboard",
    }));

    expect(offOrigin.headers.get("location")).toBe("https://cmux.test/");
    expect(recursive.headers.get("location")).toBe("https://cmux.test/");
    expect(getUser).not.toHaveBeenCalled();
  });

  test("rejects malformed request bodies without throwing", async () => {
    const response = await POST(new NextRequest(
      "https://cmux.test/handler/app-session-handoff",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{",
      },
    ));

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe("https://cmux.test/");
    expect(getUser).not.toHaveBeenCalled();
  });

  test("rejects cross-site forms without the native app header", async () => {
    const response = await POST(handoffRequest({
      refresh_token: "attacker-refresh",
      after: "/dashboard/testflight",
    }, {
      origin: "https://evil.test",
      "sec-fetch-site": "cross-site",
      "x-cmux-app-session-handoff": "",
    }));

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe("https://cmux.test/");
    expect(response.headers.get("set-cookie")).toBeNull();
    expect(getUser).not.toHaveBeenCalled();
  });

  test("fails closed when the durable handoff limiter blocks", async () => {
    durableRateLimited = true;

    const request = handoffRequest({
      refresh_token: "native-refresh",
      after: "/dashboard/testflight",
    }, {
      "x-forwarded-for": "203.0.113.20",
    });
    const response = await POST(request);

    const location = new URL(response.headers.get("location")!);
    expect(location.pathname).toBe("/handler/sign-in");
    const calls = (checkRateLimit as unknown as {
      mock: { calls: Array<[string, { request: Request }]> };
    }).mock.calls;
    expect(calls[0]?.[0]).toBe("app-session-handoff");
    expect(calls[0]?.[1].request).toBe(request);
    expect(getUser).not.toHaveBeenCalled();
  });

  test("distinguishes native rate limiting from missing authentication", async () => {
    durableRateLimited = true;

    const response = await POST(handoffRequest({
      refresh_token: "native-refresh",
      after: "/dashboard/testflight",
    }, {
      "x-cmux-app-session-response": "cookies",
      "x-forwarded-for": "203.0.113.21",
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("location")).toBeNull();
    expect(response.headers.get("set-cookie")).toBeNull();
    expect(getUser).not.toHaveBeenCalled();
  });

  test("does not let User-Agent changes bypass the local safety limit", async () => {
    for (let index = 0; index < 60; index += 1) {
      const response = await POST(handoffRequest({
        refresh_token: "native-refresh",
        after: "/dashboard/testflight",
      }, {
        "user-agent": `rotating-agent-${index}`,
        "x-forwarded-for": "203.0.113.30",
      }));
      expect(response.headers.get("location")).toBe(
        "https://cmux.test/dashboard/testflight",
      );
    }

    const blocked = await POST(handoffRequest({
      refresh_token: "native-refresh",
      after: "/dashboard/testflight",
    }, {
      "user-agent": "rotating-agent-60",
      "x-forwarded-for": "203.0.113.30",
    }));

    expect(new URL(blocked.headers.get("location")!).pathname).toBe(
      "/handler/sign-in",
    );
    expect(getUser).toHaveBeenCalledTimes(60);
  });
});
