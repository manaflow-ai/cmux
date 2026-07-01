import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

process.env.SKIP_ENV_VALIDATION = "1";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "00000000-0000-4000-8000-000000000000";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "test-publishable-key";
process.env.STACK_SECRET_SERVER_KEY = "test-secret-key";

const HANDOFF_COOKIE = "cmux-native-auth-handoff";
let handoffCookie: string | undefined;
let rawRefreshCookie: string;
let rawAccessCookie: string;
const getUser = mock(async () => null);
const signOut = mock((_options?: unknown) => Promise.resolve());

const { makeAfterSignInHandler } = await import("../app/handler/after-sign-in/handler");
const { makeSignOutAndSignInHandler } = await import("../app/handler/sign-out-and-sign-in/route");

const GET = makeAfterSignInHandler({
  projectId: "test-project",
  stackServerApp: { getUser },
  getCookieStore: async () => ({
    get: (name: string) => {
      if (name === HANDOFF_COOKIE && handoffCookie) return { value: handoffCookie };
      return undefined;
    },
    getAll: () => [
      { name: "stack-refresh-test-project", value: rawRefreshCookie },
      { name: "stack-access", value: rawAccessCookie },
    ],
  }),
});

function signInRequest(nativeReturnTo: string, handoffNonce: string): NextRequest {
  const encodedReturnTo = encodeURIComponent(nativeReturnTo);
  const encodedNonce = encodeURIComponent(handoffNonce);
  return new NextRequest(
    `https://cmux.test/handler/after-sign-in?native_app_return_to=${encodedReturnTo}&cmux_auth_handoff=${encodedNonce}`,
    {
      headers: {
        "accept-language": "en",
      },
    }
  );
}

function returnHref(html: string): string {
  const match = html.match(/<a class="primary" href="([^"]+)">Return to cmux<\/a>/);
  expect(match).toBeTruthy();
  return match![1].replaceAll("&amp;", "&");
}

function switchAccountHref(html: string): string {
  const match = html.match(/<a class="secondary" href="([^"]+)">Use a different account<\/a>/);
  expect(match).toBeTruthy();
  return match![1].replaceAll("&amp;", "&");
}

describe("after sign-in native handoff", () => {
  beforeEach(() => {
    handoffCookie = undefined;
    rawRefreshCookie = "refresh-token";
    rawAccessCookie = "access-token";
    signOut.mockClear();
  });

  test("keeps an interactive return page for verified native handoffs", async () => {
    handoffCookie = "handoff-nonce";
    const nativeReturnTo = "cmux://auth-callback?cmux_auth_state=state-123";

    const response = await GET(signInRequest(nativeReturnTo, "handoff-nonce"));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const html = await response.text();
    expect(html).toContain("Signed in to cmux");
    expect(html).toContain("Return to cmux");
    expect(html).not.toContain("window.location.replace");
    expect(html).not.toContain("http-equiv=\"refresh\"");

    const callbackURL = new URL(returnHref(html));
    expect(callbackURL.protocol).toBe("cmux:");
    expect(callbackURL.hostname).toBe("auth-callback");
    expect(callbackURL.searchParams.get("cmux_auth_state")).toBe("state-123");
    expect(callbackURL.searchParams.get("stack_refresh")).toBe("refresh-token");
    expect(callbackURL.searchParams.get("stack_access")).toBe(
      JSON.stringify(["refresh-token", "access-token"])
    );
    const setCookie = response.headers.get("set-cookie");
    expect(setCookie).toContain(`${HANDOFF_COOKIE}=;`);
    expect(setCookie).toContain("Max-Age=0");
    expect(setCookie).toContain("Path=/handler/after-sign-in");

    const switchURL = new URL(switchAccountHref(html), "https://cmux.test");
    expect(switchURL.pathname).toBe("/handler/sign-out-and-sign-in");
    const nativeSignInTarget = new URL(
      switchURL.searchParams.get("after_auth_return_to")!,
      "https://cmux.test"
    );
    expect(nativeSignInTarget.pathname).toBe("/handler/native-sign-in");
    const afterSignInTarget = new URL(
      nativeSignInTarget.searchParams.get("after_auth_return_to")!,
      "https://cmux.test"
    );
    expect(afterSignInTarget.pathname).toBe("/handler/after-sign-in");
    expect(afterSignInTarget.searchParams.get("native_app_return_to")).toBe(nativeReturnTo);
    expect(afterSignInTarget.searchParams.has("after_auth_return_to")).toBe(false);
  });

  test("keeps the manual return page when the handoff nonce is not verified", async () => {
    handoffCookie = "different-nonce";
    const nativeReturnTo = "cmux://auth-callback?cmux_auth_state=state-123";

    const response = await GET(signInRequest(nativeReturnTo, "handoff-nonce"));

    expect(response.status).toBe(200);
    const html = await response.text();
    expect(html).toContain("Signed in to cmux");
    expect(html).toContain("Return to cmux");
    expect(html).not.toContain("window.location.replace");
    expect(returnHref(html)).toContain("cmux://auth-callback");
  });

  test("does not crash on malformed percent-encoded stack cookies", async () => {
    handoffCookie = "handoff-nonce";
    rawRefreshCookie = "%";
    rawAccessCookie = "%";
    const nativeReturnTo = "cmux://auth-callback?cmux_auth_state=state-123";

    const response = await GET(signInRequest(nativeReturnTo, "handoff-nonce"));

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://cmux.test/");
  });
});

describe("sign out and sign back in", () => {
  const GET = makeSignOutAndSignInHandler({
    projectId: "test-project",
    signOut: async (options) => {
      await signOut(options);
    },
  });

  beforeEach(() => {
    signOut.mockClear();
  });

  function switchRequest(
    afterAuthReturnTo: string,
    headers: Record<string, string> = {},
    includeDefaultFetchSite = true
  ): NextRequest {
    return new NextRequest(
      `https://cmux.test/handler/sign-out-and-sign-in?after_auth_return_to=${encodeURIComponent(afterAuthReturnTo)}`,
      {
        headers: {
          ...(includeDefaultFetchSite ? { "sec-fetch-site": "same-origin" } : {}),
          cookie:
            "stack-access=access-token; __Host-stack-access=secure-access-token; stack-refresh-test-project=refresh-token; __Host-stack-refresh-test-project=host-refresh-token; __Secure-stack-refresh-test-project=secure-refresh-token; stack-refresh-test-project--default=branch-refresh-token; __Host-stack-refresh-test-project--default=secure-branch-refresh-token; stack-refresh-test-project--custom-CNW62VBGDHJJWRVFDM=custom-refresh-token; __Secure-stack-refresh-test-project--custom-CNW62VBGDHJJWRVFDM=secure-custom-refresh-token; unrelated=value",
          ...headers,
        },
      }
    );
  }

  test("signs out and redirects back to the native sign-in flow", async () => {
    const afterSignIn = "/handler/after-sign-in?native_app_return_to=cmux%3A%2F%2Fauth-callback%3Fcmux_auth_state%3Dstate-123";
    const nativeSignIn = `/handler/native-sign-in?after_auth_return_to=${encodeURIComponent(afterSignIn)}`;

    const response = await GET(switchRequest(nativeSignIn));

    expect(signOut).toHaveBeenCalledWith({
      redirectUrl: `https://cmux.test${nativeSignIn}`,
    });
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(`https://cmux.test${nativeSignIn}`);

    const setCookie = response.headers.get("set-cookie");
    expect(setCookie).toContain("stack-access=;");
    expect(setCookie).toContain("__Host-stack-access=;");
    expect(setCookie).toContain("stack-refresh-test-project=;");
    expect(setCookie).toContain("__Host-stack-refresh-test-project=;");
    expect(setCookie).toContain("__Secure-stack-refresh-test-project=;");
    expect(setCookie).toContain("stack-refresh-test-project--default=;");
    expect(setCookie).toContain("__Host-stack-refresh-test-project--default=;");
    expect(setCookie).toMatch(
      /stack-refresh-test-project--custom-CNW62VBGDHJJWRVFDM=;[^,]*Domain=example\.com/
    );
    expect(setCookie).toMatch(
      /__Secure-stack-refresh-test-project--custom-CNW62VBGDHJJWRVFDM=;[^,]*Domain=example\.com/
    );
    expect(setCookie).not.toContain("unrelated=;");
  });

  test("still clears cookies and redirects when Stack sign-out throws", async () => {
    const GET = makeSignOutAndSignInHandler({
      projectId: "test-project",
      signOut: async () => {
        throw new Error("stack unavailable");
      },
    });
    const afterSignIn = "/handler/after-sign-in?native_app_return_to=cmux%3A%2F%2Fauth-callback%3Fcmux_auth_state%3Dstate-123";
    const nativeSignIn = `/handler/native-sign-in?after_auth_return_to=${encodeURIComponent(afterSignIn)}`;

    const response = await GET(switchRequest(nativeSignIn));

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(`https://cmux.test${nativeSignIn}`);
    const setCookie = response.headers.get("set-cookie");
    expect(setCookie).toContain("stack-access=;");
    expect(setCookie).toContain("__Host-stack-access=;");
  });

  test("rejects non-native sign-in redirect targets", async () => {
    const response = await GET(switchRequest("/docs"));

    expect(signOut).not.toHaveBeenCalled();
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://cmux.test/");
  });

  test("rejects nested after-sign-in redirect targets", async () => {
    const afterSignIn =
      "/handler/after-sign-in?native_app_return_to=cmux%3A%2F%2Fauth-callback%3Fcmux_auth_state%3Dstate-123&after_auth_return_to=%2Fdocs";
    const nativeSignIn = `/handler/native-sign-in?after_auth_return_to=${encodeURIComponent(afterSignIn)}`;

    const response = await GET(switchRequest(nativeSignIn));

    expect(signOut).not.toHaveBeenCalled();
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://cmux.test/");
  });

  test("rejects cross-site attempts to force sign-out", async () => {
    const afterSignIn = "/handler/after-sign-in?native_app_return_to=cmux%3A%2F%2Fauth-callback%3Fcmux_auth_state%3Dstate-123";
    const nativeSignIn = `/handler/native-sign-in?after_auth_return_to=${encodeURIComponent(afterSignIn)}`;

    const response = await GET(switchRequest(nativeSignIn, { "sec-fetch-site": "cross-site" }));

    expect(signOut).not.toHaveBeenCalled();
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://cmux.test/");
  });

  test("rejects sign-out attempts without a fetch metadata signal", async () => {
    const afterSignIn = "/handler/after-sign-in?native_app_return_to=cmux%3A%2F%2Fauth-callback%3Fcmux_auth_state%3Dstate-123";
    const nativeSignIn = `/handler/native-sign-in?after_auth_return_to=${encodeURIComponent(afterSignIn)}`;

    const response = await GET(switchRequest(nativeSignIn, {}, false));

    expect(signOut).not.toHaveBeenCalled();
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://cmux.test/");
  });
});
