import { describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

process.env.SKIP_ENV_VALIDATION = "1";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "test-project";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "test-publishable-key";
process.env.STACK_SECRET_SERVER_KEY = "test-secret-key";

const HANDOFF_COOKIE = "cmux-native-auth-handoff";
let handoffCookie: string | undefined;
const getUser = mock(async () => null);

const { makeAfterSignInHandler } = await import("../app/handler/after-sign-in/handler");

const GET = makeAfterSignInHandler({
  projectId: "test-project",
  stackServerApp: { getUser },
  getCookieStore: async () => ({
    get: (name: string) => {
      if (name === HANDOFF_COOKIE && handoffCookie) return { value: handoffCookie };
      return undefined;
    },
    getAll: () => [
      { name: "stack-refresh-test-project", value: "refresh-token" },
      { name: "stack-access", value: "access-token" },
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
  const match = html.match(/<a href="([^"]+)">Return to cmux<\/a>/);
  expect(match).toBeTruthy();
  return match![1].replaceAll("&amp;", "&");
}

describe("after sign-in native handoff", () => {
  test("keeps a fallback page for verified native auto-open handoffs", async () => {
    handoffCookie = "handoff-nonce";
    const nativeReturnTo = "cmux://auth-callback?cmux_auth_state=state-123";

    const response = await GET(signInRequest(nativeReturnTo, "handoff-nonce"));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const html = await response.text();
    expect(html).toContain("Signed in to cmux");
    expect(html).toContain("Return to cmux");
    expect(html).toContain("window.location.replace");
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
});
