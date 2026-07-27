import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

process.env.SKIP_ENV_VALIDATION = "1";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "12345678-1234-4123-8123-123456789abc";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "test-publishable-key";
process.env.STACK_SECRET_SERVER_KEY = "test-secret-key";

const getTokens = mock(async () => ({
  refreshToken: "fresh-refresh",
  accessToken: "fresh-access",
}));
const createSession = mock(async () => ({ getTokens }));
const getUser = mock(async () => ({ createSession }));

const { makeAppSessionHandoffHandler } = await import(
  "../app/handler/app-session-handoff/route"
);

const POST = makeAppSessionHandoffHandler({
  projectId: "12345678-1234-4123-8123-123456789abc",
  stackServerApp: { getUser },
  now: () => 1_721_955_600_000,
});

function handoffRequest(body: Record<string, string>): NextRequest {
  return new NextRequest("https://cmux.test/handler/app-session-handoff", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "user-agent": "bun-test",
      "x-forwarded-for": "203.0.113.10",
    },
    body: new URLSearchParams(body),
  });
}

describe("app session handoff", () => {
  beforeEach(() => {
    getUser.mockClear();
    createSession.mockClear();
    getTokens.mockClear();
    getUser.mockResolvedValue({ createSession });
    getTokens.mockResolvedValue({
      refreshToken: "fresh-refresh",
      accessToken: "fresh-access",
    });
  });

  test("validates native tokens, sets Stack cookies, and redirects to the app path", async () => {
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
      tokenStore: {
        accessToken: "native-access",
        refreshToken: "native-refresh",
      },
    });
    expect(createSession).toHaveBeenCalledWith({
      expiresInMillis: 30 * 24 * 60 * 60 * 1000,
    });

    const setCookie = response.headers.get("set-cookie") ?? "";
    expect(setCookie).toContain("hexclave-access=");
    expect(setCookie).toContain(
      encodeURIComponent(JSON.stringify(["fresh-refresh", "fresh-access"])),
    );
    expect(setCookie).toContain(
      "__Host-hexclave-refresh-12345678-1234-4123-8123-123456789abc--default=",
    );
    expect(setCookie).toContain(
      encodeURIComponent(JSON.stringify({
        refresh_token: "fresh-refresh",
        updated_at_millis: 1_721_955_600_000,
      })),
    );
    expect(setCookie.toLowerCase()).not.toContain("httponly");
    expect(setCookie).not.toContain("native-refresh");
    expect(setCookie).not.toContain("native-access");
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
});
