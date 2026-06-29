import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

process.env.SKIP_ENV_VALIDATION = "1";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "test-project";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "test-publishable-key";
process.env.STACK_SECRET_SERVER_KEY = "test-secret-key";

const HANDOFF_COOKIE = "cmux-native-auth-handoff";
let handoffCookie: string | undefined;
let rawRefreshCookie: string;
let rawAccessCookie: string;
const getUser = mock(async () => null);

const { makeAfterSignInHandler } = await import("../app/handler/after-sign-in/handler");
const nativeReturn = await import("../app/handler/after-sign-in/native-return");
const { mobileMagicLinkCallbackModel } = await import(
  "../app/handler/mobile-magic-link-callback/handler"
);
const mobileMagicLink = await import("../app/handler/mobile-magic-link-callback/route");

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
  const match = html.match(/<a href="([^"]+)">[^<]+<\/a>/);
  expect(match).toBeTruthy();
  return match![1].replaceAll("&amp;", "&");
}

describe("after sign-in native handoff", () => {
  beforeEach(() => {
    handoffCookie = undefined;
    rawRefreshCookie = "refresh-token";
    rawAccessCookie = "access-token";
  });

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

  test("returns only a safe error callback to verified stateful mobile handoffs", async () => {
    handoffCookie = "handoff-nonce";
    const nativeReturnTo = "cmux-ios-beta://auth-callback?cmux_auth_state=state-123";

    const response = await GET(signInRequest(nativeReturnTo, "handoff-nonce"));

    expect(response.status).toBe(200);
    const html = await response.text();
    expect(html).toContain("Return to cmux TestFlight");
    expect(html).toContain("window.location.replace");
    const callbackURL = new URL(returnHref(html));
    expect(callbackURL.protocol).toBe("cmux-ios-beta:");
    expect(callbackURL.searchParams.get("cmux_auth_state")).toBe("state-123");
    expect(callbackURL.searchParams.get("stack_refresh")).toBeNull();
    expect(callbackURL.searchParams.get("stack_access")).toBeNull();
    expect(callbackURL.searchParams.get("cmux_auth_error")).toBe("mobile_web_sign_in_requires_code");
  });

  test("keeps a safe mobile return page when the handoff nonce is not verified", async () => {
    handoffCookie = "different-nonce";
    const nativeReturnTo = "cmux-ios-beta://auth-callback?cmux_auth_state=state-123";

    const response = await GET(signInRequest(nativeReturnTo, "handoff-nonce"));

    expect(response.status).toBe(200);
    const html = await response.text();
    expect(html).toContain("Return to cmux TestFlight");
    expect(html).not.toContain("window.location.replace");
    const callbackURL = new URL(returnHref(html));
    expect(callbackURL.searchParams.get("stack_refresh")).toBeNull();
    expect(callbackURL.searchParams.get("stack_access")).toBeNull();
    expect(callbackURL.searchParams.get("cmux_auth_error")).toBe("mobile_web_sign_in_requires_code");
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

describe("after sign in native return allowlist", () => {
  const messages = {
    title: "Signed in",
    body: "Return",
    button: "Return to cmux",
    iphoneButton: "Return to cmux on iPhone",
    testFlightButton: "Return to cmux TestFlight",
  };

  test("allows production macOS and stateful iOS callback schemes", () => {
    const request = new NextRequest("https://cmux.com/handler/after-sign-in");

    expect(nativeReturn.isAllowedNativeReturnTo("cmux://auth-callback", request)).toBe(true);
    expect(nativeReturn.isAllowedNativeReturnTo("cmux-nightly://auth-callback", request)).toBe(true);
    expect(nativeReturn.isAllowedNativeReturnTo("cmux-ios://auth-callback?cmux_auth_state=state-1", request)).toBe(true);
    expect(nativeReturn.isAllowedNativeReturnTo("cmux-ios-beta://auth-callback?cmux_auth_state=state-1", request)).toBe(true);
  });

  test("rejects state-less iOS custom-scheme callbacks before adding tokens", () => {
    const request = new NextRequest("https://cmux.com/handler/after-sign-in");

    expect(nativeReturn.isAllowedNativeReturnTo("cmux-ios://auth-callback", request)).toBe(false);
    expect(nativeReturn.isAllowedNativeReturnTo("cmux-ios-beta://auth-callback", request)).toBe(false);
  });

  test("keeps dev callback schemes local-only", () => {
    const productionRequest = new NextRequest("https://cmux.com/handler/after-sign-in");
    const localRequest = new NextRequest("http://localhost:3000/handler/after-sign-in");

    expect(nativeReturn.isAllowedNativeReturnTo("cmux-dev://auth-callback", productionRequest)).toBe(false);
    expect(nativeReturn.isAllowedNativeReturnTo("cmux-dev://auth-callback", localRequest)).toBe(true);
    expect(nativeReturn.isAllowedNativeReturnTo("cmux-ios-dev://auth-callback?cmux_auth_state=state-1", productionRequest)).toBe(false);
    expect(nativeReturn.isAllowedNativeReturnTo("cmux-ios-dev://auth-callback?cmux_auth_state=state-1", localRequest)).toBe(true);
  });

  test("adds tokens only to the desktop fallback link", () => {
    const links = nativeReturn.fallbackNativeLinks("refresh-token", "access-token", messages);

    expect(links.map((link) => new URL(link.href).protocol)).toEqual(["cmux:"]);
    for (const link of links) {
      const url = new URL(link.href);
      expect(url.searchParams.get("stack_refresh")).toBe("refresh-token");
      expect(url.searchParams.get("stack_access")).toBe("access-token");
    }
  });

  test("uses desktop-only fallback links for desktop native sign-in", () => {
    const links = nativeReturn.fallbackNativeLinks("refresh-token", "access-token", messages, "desktop");

    expect(links.map((link) => new URL(link.href).protocol)).toEqual(["cmux:"]);
    expect(links.map((link) => link.label)).toEqual(["Return to cmux"]);
  });

  test("does not emit state-less mobile token fallback links", () => {
    const links = nativeReturn.fallbackNativeLinks("refresh-token", "access-token", messages, "mobile");

    expect(links).toEqual([]);
  });
});

describe("magic-link callback", () => {
  test("returns a safe app callback for mobile without consuming or forwarding Stack code", async () => {
    const nativeReturnTo = encodeURIComponent("cmux-ios-beta://auth-callback?cmux_auth_state=state-123");
    const request = new NextRequest(
      `https://cmux.com/handler/magic-link-callback?native_app_return_to=${nativeReturnTo}&code=stack-code`
    );

    const model = await mobileMagicLinkCallbackModel(request);

    expect(model).not.toBeNull();
    expect(model?.messages.title).toBe("Open cmux to finish sign in");
    expect(model?.label).toBe("Return to cmux TestFlight");
    const href = model!.href;
    expect(href).not.toContain("stack-code");
    const url = new URL(href);
    expect(url.protocol).toBe("cmux-ios-beta:");
    expect(url.searchParams.get("cmux_auth_state")).toBe("state-123");
    expect(url.searchParams.get("cmux_auth_error")).toBe("mobile_web_sign_in_requires_code");
    expect(url.searchParams.get("stack_refresh")).toBeNull();
    expect(url.searchParams.get("stack_access")).toBeNull();
  });

  test("keeps the old mobile callback path as a safe alias", async () => {
    const nativeReturnTo = encodeURIComponent("cmux-ios://auth-callback?cmux_auth_state=state-123");
    const request = new NextRequest(
      `https://cmux.com/handler/mobile-magic-link-callback?native_app_return_to=${nativeReturnTo}&code=stack-code`
    );

    const response = await mobileMagicLink.GET(request);

    expect(response.status).toBe(200);
    const href = returnHref(await response.text());
    expect(new URL(href).protocol).toBe("cmux-ios:");
  });
});
