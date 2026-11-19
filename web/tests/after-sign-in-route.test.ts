import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

process.env.SKIP_ENV_VALIDATION = "1";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "00000000-0000-4000-8000-000000000000";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "test-publishable-key";
process.env.STACK_SECRET_SERVER_KEY = "test-secret-key";

type TestStackAuthSession = {
  getTokens: () => Promise<{ refreshToken?: string; accessToken?: string }>;
};
type TestStackAuthUser = {
  id?: string;
  primaryEmail?: string | null;
  primaryEmailVerified?: boolean;
  isAnonymous?: boolean;
  createSession: (options: { expiresInMillis: number }) => Promise<TestStackAuthSession>;
};

let rawRefreshCookie: string;
let rawAccessCookie: string;
let getUserResponses: Array<TestStackAuthUser | null | Error> = [];
let defaultUser: TestStackAuthUser | null = null;
let defaultCreateSession: ReturnType<typeof signedInUser>["createSession"];
let promotionShouldFail = false;
const claimVerifiedBilling = mock(async () => undefined);
const applyAdminGrants = mock(async () => undefined);
const getUser = mock(async (): Promise<TestStackAuthUser | null> => {
  // With no scripted answer, the browser is signed in as `defaultUser`.
  const next = getUserResponses.length > 0 ? getUserResponses.shift()! : defaultUser;
  if (next instanceof Error) throw next;
  return next;
});
const signOut = mock((options?: unknown) => {
  void options;
  return Promise.resolve();
});
const promoteVerifiedAnonymousUser = mock(async () => {
  if (promotionShouldFail) throw new Error("Stack promotion unavailable");
});

const { makeAfterSignInHandler } = await import("../app/handler/after-sign-in/handler");
const { appPricingNativeReturnURL } = await import("../app/lib/billing");
const { GET: startNativeSignIn } = await import("../app/handler/native-sign-in/route");
const { makeSignOutAndSignInHandler } = await import("../app/handler/sign-out-and-sign-in/route");
const { hashNativeSignInCode, s256CodeChallenge } = await import("../app/lib/native-sign-in-codes");
type NativeSignInCodeRecord = import("../app/lib/native-sign-in-codes").NativeSignInCodeRecord;

const CONFIRM_COOKIE = "__Host-cmux-native-auth-confirm";
const VERIFIER = "v".repeat(43) + "-verifier_for.tests~0123456789";
const CHALLENGE = s256CodeChallenge(VERIFIER);
let confirmCookie: string | undefined;
const storedCodes = new Map<string, NativeSignInCodeRecord>();
const codeStore = {
  insert: async (record: NativeSignInCodeRecord) => {
    storedCodes.set(record.codeHash, record);
  },
  consume: async (codeHash: string, now: Date) => {
    const record = storedCodes.get(codeHash) ?? null;
    storedCodes.delete(codeHash);
    return record && record.expiresAt > now ? record : null;
  },
};

const GET = makeAfterSignInHandler({
  projectId: "test-project",
  stackServerApp: { getUser },
  promoteVerifiedAnonymousUser,
  claimVerifiedBilling,
  applyAdminGrants,
  nativeSignInCodeStore: codeStore,
  getCookieStore: async () => ({
    get: (name: string) => {
      if (name === CONFIRM_COOKIE && confirmCookie) return { value: confirmCookie };
      return undefined;
    },
    getAll: () => [
      { name: "stack-refresh-test-project", value: rawRefreshCookie },
      { name: "stack-access", value: rawAccessCookie },
    ],
  }),
});

function signInRequest(
  nativeReturnTo: string,
  handoffNonce: string,
  webReturnTo?: string,
  origin = "https://cmux.test",
  codeChallenge: string | null = CHALLENGE,
): NextRequest {
  const encodedReturnTo = encodeURIComponent(nativeReturnTo);
  const encodedNonce = encodeURIComponent(handoffNonce);
  const encodedWebReturnTo = webReturnTo
    ? `&web_return_to=${encodeURIComponent(webReturnTo)}`
    : "";
  const pkce = codeChallenge === null
    ? ""
    : `&code_challenge=${encodeURIComponent(codeChallenge)}&code_challenge_method=S256`;
  return new NextRequest(
    `${origin}/handler/after-sign-in?native_app_return_to=${encodedReturnTo}&cmux_auth_handoff=${encodedNonce}${encodedWebReturnTo}${pkce}`,
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

/** A signed-in account whose session must never be minted by the callback itself. */
function signedInUser(id = "user-1") {
  const createSession = mock(async () => ({
    getTokens: async () => ({ refreshToken: "minted-refresh", accessToken: "minted-access" }),
  }));
  return { user: { id, primaryEmail: null, createSession }, createSession };
}

/** Follow the confirmation page's own button, carrying the cookie it set. */
function confirmFromPage(html: string, response: Response, origin = "https://cmux.test"): NextRequest {
  const href = returnHref(html);
  const confirmURL = new URL(href, origin);
  const nonce = confirmURL.searchParams.get("cmux_auth_confirm");
  expect(nonce).toMatch(/^[A-Za-z0-9_-]{43}$/);
  confirmCookie = setCookieValue(response, CONFIRM_COOKIE);
  // The cookie carries the nonce bound to its purpose and path, not the bare nonce.
  expect(confirmCookie).not.toBe(nonce);
  expect(confirmCookie).toContain(nonce!);
  return new NextRequest(confirmURL, { headers: { "accept-language": "en" } });
}

/** The decoded value `response` sets for cookie `name`. */
function setCookieValue(response: Response, name: string): string {
  const header = response.headers.get("set-cookie") ?? "";
  const match = new RegExp(`(?:^|,\\s*)${name.replace(/[$]/g, "\\$&")}=([^;]*)`).exec(header);
  expect(match).toBeTruthy();
  return decodeURIComponent(match![1]);
}

/** The person signs in and clicks the confirmation page's button. */
async function handOff(request: NextRequest): Promise<Response> {
  const page = await GET(request);
  if (page.status !== 200) return page;
  return GET(confirmFromPage(await page.text(), page, request.nextUrl.origin));
}

function expectNoTokens(value: string | null) {
  expect(value ?? "").not.toContain("stack_refresh");
  expect(value ?? "").not.toContain("stack_access");
  expect(value ?? "").not.toContain("minted-refresh");
  expect(value ?? "").not.toContain("refresh-token");
}

describe("after sign-in native handoff", () => {
  beforeEach(() => {
    confirmCookie = undefined;
    storedCodes.clear();
    const signedIn = signedInUser();
    defaultUser = signedIn.user;
    defaultCreateSession = signedIn.createSession;
    rawRefreshCookie = "refresh-token";
    rawAccessCookie = "access-token";
    getUserResponses = [];
    promotionShouldFail = false;
    getUser.mockClear();
    signOut.mockClear();
    promoteVerifiedAnonymousUser.mockClear();
    claimVerifiedBilling.mockClear();
    applyAdminGrants.mockClear();
  });

  test("native sign-in sets nothing that could skip the confirmation click", async () => {
    const nativeReturnTo = "cmux://auth-callback?cmux_auth_state=state-123";
    const afterSignIn = new URL("/handler/after-sign-in", "https://cmux.test");
    afterSignIn.searchParams.set("native_app_return_to", nativeReturnTo);
    const startURL = new URL("/handler/native-sign-in", "https://cmux.test");
    startURL.searchParams.set("after_auth_return_to", `${afterSignIn.pathname}${afterSignIn.search}`);

    const startResponse = startNativeSignIn(new NextRequest(startURL, { headers: { "sec-fetch-site": "none" } }));

    expect(startResponse.headers.get("set-cookie")).toBeNull();
    const signInURL = new URL(startResponse.headers.get("location")!);
    const callbackURL = new URL(signInURL.searchParams.get("after_auth_return_to")!);
    expect(callbackURL.searchParams.has("cmux_auth_handoff")).toBe(false);
  });

  test("the confirmation cookie is __Host-, Secure, Path=/ and cleared by the hand-off", async () => {
    const page = await GET(signInRequest("cmux://auth-callback?cmux_auth_state=s", "unused"));
    const issued = page.headers.get("set-cookie")!;
    expect(issued).toContain(`${CONFIRM_COOKIE}=`);
    expect(issued).toContain("Path=/");
    expect(issued).not.toContain("Path=/handler");
    expect(issued).not.toMatch(/Domain=/i);
    expect(issued).toContain("Secure");
    expect(issued).toContain("HttpOnly");
    expect(issued).toContain("SameSite=lax");
    expect(issued).toContain("Max-Age=600");

    const handedOff = await GET(confirmFromPage(await page.text(), page));
    const cleared = handedOff.headers.get("set-cookie")!;
    expect(cleared).toContain(`${CONFIRM_COOKIE}=;`);
    expect(cleared).toContain("Max-Age=0");
    expect(cleared).toContain("Path=/");
  });

  test("a bare nonce planted as the cookie value is not a confirmation", async () => {
    const nonce = "n".repeat(43);
    confirmCookie = nonce;
    const request = signInRequest("cmux://auth-callback?cmux_auth_state=s", "unused");
    request.nextUrl.searchParams.set("cmux_auth_confirm", nonce);

    const response = await GET(new NextRequest(request.nextUrl, { headers: { "accept-language": "en" } }));

    expect(response.status).toBe(200);
    expect(storedCodes.size).toBe(0);
  });

  test("a confirmation bound to after-sign-in is refused on another path", async () => {
    const page = await GET(signInRequest("cmux://auth-callback?cmux_auth_state=s", "unused"));
    const confirmed = confirmFromPage(await page.text(), page);
    const elsewhere = new URL(confirmed.nextUrl);
    elsewhere.pathname = "/handler/other";
    const { verifiedNativeConfirmation } = await import("../app/handler/native-handoff-cookie");
    const store = { get: (name: string) => (name === CONFIRM_COOKIE ? { value: confirmCookie! } : undefined) };

    expect(verifiedNativeConfirmation(confirmed, store)).toBe(true);
    expect(verifiedNativeConfirmation(new NextRequest(elsewhere), store)).toBe(false);
  });

  test("the page names the signed-in account and the destination app", async () => {
    getUserResponses = [{ id: "user-1", primaryEmail: "person@example.com", createSession: defaultCreateSession }];

    const page = await GET(signInRequest("cmux-rc://auth-callback?cmux_auth_state=s", "unused"));

    expect(page.status).toBe(200);
    const html = await page.text();
    expect(html).toContain("<strong>person@example.com</strong>");
    expect(html).toContain("<strong>cmux RC</strong>");
    expect(html).toContain("Only continue if you just started signing in from this app.");
    expect(storedCodes.size).toBe(0);
  });

  test("native sign-in carries the app's challenge into the callback and refuses a bad one", async () => {
    const afterSignIn = new URL("/handler/after-sign-in", "https://cmux.test");
    afterSignIn.searchParams.set("native_app_return_to", "cmux://auth-callback?cmux_auth_state=s");
    const startURL = new URL("/handler/native-sign-in", "https://cmux.test");
    startURL.searchParams.set("after_auth_return_to", `${afterSignIn.pathname}${afterSignIn.search}`);
    startURL.searchParams.set("code_challenge", CHALLENGE);
    startURL.searchParams.set("code_challenge_method", "S256");

    const started = startNativeSignIn(new NextRequest(startURL, { headers: { "sec-fetch-site": "none" } }));
    const signInURL = new URL(started.headers.get("location")!);
    const callbackURL = new URL(signInURL.searchParams.get("after_auth_return_to")!);
    expect(callbackURL.searchParams.get("code_challenge")).toBe(CHALLENGE);
    expect(callbackURL.searchParams.get("code_challenge_method")).toBe("S256");

    for (const [challenge, method] of [["short", "S256"], [CHALLENGE, "plain"], [CHALLENGE, null]] as const) {
      const bad = new URL(startURL);
      bad.searchParams.set("code_challenge", challenge);
      if (method) bad.searchParams.set("code_challenge_method", method);
      else bad.searchParams.delete("code_challenge_method");
      const refused = startNativeSignIn(new NextRequest(bad, { headers: { "sec-fetch-site": "none" } }));
      expect(refused.headers.get("location")).toBe("https://cmux.test/");
    }
  });

  test("a PKCE request never redirects without the click, even for an app-initiated attempt", async () => {
    // A local app can start its own sign-in for any allowed scheme; a
    // signed-in browser must not hand it a code by itself.
    const response = await GET(signInRequest("cmux-rc://auth-callback?cmux_auth_state=attacker", "unused"));

    expect(response.status).toBe(200);
    expect(response.headers.get("location")).toBeNull();
    expect(storedCodes.size).toBe(0);
  });

  test("after the click, hands off a one-time code and no tokens", async () => {
    const nativeReturnTo = "cmux://auth-callback?cmux_auth_state=state-123";

    const response = await handOff(signInRequest(nativeReturnTo, "handoff-nonce"));

    expect(response.status).toBe(307);
    expect(response.headers.get("cache-control")).toBe("no-store");

    const location = response.headers.get("location");
    expect(location).toBeTruthy();
    expectNoTokens(location);
    const callbackURL = new URL(location!);
    expect(callbackURL.protocol).toBe("cmux:");
    expect(callbackURL.hostname).toBe("auth-callback");
    expect(callbackURL.searchParams.get("cmux_auth_state")).toBe("state-123");
    expect([...callbackURL.searchParams.keys()].sort()).toEqual(["cmux_auth_state", "code"]);
    const code = callbackURL.searchParams.get("code")!;
    expect(code).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const record = storedCodes.get(hashNativeSignInCode(code));
    expect(record?.userId).toBe("user-1");
    expect(record?.codeChallenge).toBe(CHALLENGE);
    expect(record?.scheme).toBe("cmux");
    expect(record?.issuer).toBe("test-project");
    expect(record!.expiresAt.getTime() - Date.now()).toBeLessThanOrEqual(60_000);
    // The session is minted only when the app redeems the code.
    expect(defaultCreateSession).not.toHaveBeenCalled();
  });

  test("redirects verified release-candidate handoffs directly to cmux-rc", async () => {
    const nativeReturnTo = "cmux-rc://auth-callback?cmux_auth_state=state-rc";

    const response = await handOff(signInRequest(nativeReturnTo, "handoff-nonce"));

    expect(response.status).toBe(307);
    const location = response.headers.get("location");
    expect(location).toBeTruthy();
    const callbackURL = new URL(location!);
    expect(callbackURL.protocol).toBe("cmux-rc:");
    expect(callbackURL.hostname).toBe("auth-callback");
    expect(callbackURL.searchParams.get("cmux_auth_state")).toBe("state-rc");
  });

  test("redirects verified cmux NEXT handoffs directly to cmux-next", async () => {
    // nightly-next installs beside classic NIGHTLY as cmux NEXT with its own
    // scheme, so its sign-in never lands in the NIGHTLY app.
    const nativeReturnTo = "cmux-next://auth-callback?cmux_auth_state=state-next";

    const response = await handOff(signInRequest(nativeReturnTo, "handoff-nonce"));

    expect(response.status).toBe(307);
    const callbackURL = new URL(response.headers.get("location")!);
    expect(callbackURL.protocol).toBe("cmux-next:");
    expect(callbackURL.hostname).toBe("auth-callback");
    expect(callbackURL.searchParams.get("cmux_auth_state")).toBe("state-next");
  });

  test("redirects verified signed NEXT DEV handoffs on staging to cmux-next-dev", async () => {
    // Signed NEXT DEV is a Release build that signs into staging, so its
    // callback must survive the deployed after-sign-in handoff there.
    const nativeReturnTo = "cmux-next-dev://auth-callback?cmux_auth_state=state-next-dev";

    const response = await handOff(
      signInRequest(nativeReturnTo, "handoff-nonce", undefined, "https://cmux-staging.vercel.app"),
    );

    expect(response.status).toBe(307);
    const callbackURL = new URL(response.headers.get("location")!);
    expect(callbackURL.protocol).toBe("cmux-next-dev:");
    expect(callbackURL.hostname).toBe("auth-callback");
    expect(callbackURL.searchParams.get("cmux_auth_state")).toBe("state-next-dev");
  });

  test("rejects signed NEXT DEV handoffs on production", async () => {
    const nativeReturnTo = "cmux-next-dev://auth-callback?cmux_auth_state=state-next-dev";

    const response = await GET(
      signInRequest(nativeReturnTo, "handoff-nonce", undefined, "https://cmux.com"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://cmux.com/");
  });

  for (const scheme of ["cmux-dev", "cmux-dev-pr-28950-next-cloud-dev-v1"]) {
    test(`redirects verified ${scheme} handoffs on staging`, async () => {
      // Debug and tagged fleet builds sign in on staging by default (CloudConfiguration.resolve).
        const nativeReturnTo = `${scheme}://auth-callback?cmux_auth_state=state-dev`;

      const response = await handOff(
        signInRequest(nativeReturnTo, "handoff-nonce", undefined, "https://cmux-staging.vercel.app"),
      );

      expect(response.status).toBe(307);
      const callbackURL = new URL(response.headers.get("location")!);
      expect(callbackURL.protocol).toBe(`${scheme}:`);
      expect(callbackURL.searchParams.get("cmux_auth_state")).toBe("state-dev");
    });

    test(`rejects ${scheme} handoffs on production`, async () => {
        const nativeReturnTo = `${scheme}://auth-callback?cmux_auth_state=state-dev`;

      const response = await GET(
        signInRequest(nativeReturnTo, "handoff-nonce", undefined, "https://cmux.com"),
      );

      expect(response.status).toBe(307);
      expect(response.headers.get("location")).toBe("https://cmux.com/");
    });
  }

  test("keeps the manual return page when the handoff nonce is not verified", async () => {
    const nativeReturnTo = "cmux://auth-callback?cmux_auth_state=state-123";

    const response = await GET(signInRequest(nativeReturnTo, "handoff-nonce"));

    expect(response.status).toBe(200);
    const html = await response.text();
    expect(html).toContain("Signed in to cmux");
    expect(html).toContain("Return to cmux");
    expect(html).not.toContain("window.location.replace");
    expectNoTokens(html);
    expect(html).not.toContain("cmux://auth-callback?");
    // Nothing exists until the click: no code, no session.
    expect(storedCodes.size).toBe(0);
    expect(defaultCreateSession).not.toHaveBeenCalled();

    // The button returns here with this page's nonce, then hands off a code.
    const confirmed = await GET(confirmFromPage(html, response));
    expect(confirmed.status).toBe(307);
    const location = confirmed.headers.get("location");
    expectNoTokens(location);
    const callbackURL = new URL(location!);
    expect(callbackURL.protocol).toBe("cmux:");
    expect(callbackURL.searchParams.get("cmux_auth_state")).toBe("state-123");
    expect(storedCodes.has(hashNativeSignInCode(callbackURL.searchParams.get("code")!))).toBe(true);
    expect(confirmed.headers.get("set-cookie")).toContain(`${CONFIRM_COOKIE}=;`);

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
    expect(afterSignInTarget.searchParams.get("code_challenge")).toBe(CHALLENGE);
    expect(afterSignInTarget.searchParams.has("after_auth_return_to")).toBe(false);
  });

  test("preserves the embedded pricing return path when switching accounts", async () => {
    const nativeReturnTo = "cmux://auth-callback";
    const webReturnTo =
      "/app-pricing?cmux_app=1&cmux_scheme=cmux-dev-test&appearance=dark&interval=year";

    const response = await GET(
      signInRequest(nativeReturnTo, "handoff-nonce", webReturnTo),
    );

    expect(response.status).toBe(200);
    const html = await response.text();
    const switchURL = new URL(switchAccountHref(html), "https://cmux.test");
    const nativeSignInTarget = new URL(
      switchURL.searchParams.get("after_auth_return_to")!,
      "https://cmux.test",
    );
    const afterSignInTarget = new URL(
      nativeSignInTarget.searchParams.get("after_auth_return_to")!,
      "https://cmux.test",
    );
    expect(afterSignInTarget.searchParams.get("web_return_to")).toBe(webReturnTo);
  });

  test("a plain visit with no native return target mints nothing and offers no tokens", async () => {
    const response = await GET(
      new NextRequest("https://cmux.test/handler/after-sign-in", {
        headers: {
          "accept-language": "en",
        },
      })
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://cmux.test/");
    expect(defaultCreateSession).not.toHaveBeenCalled();
    expect(storedCodes.size).toBe(0);
  });

  test("refuses a malformed challenge or another method instead of downgrading", async () => {
    const nativeReturnTo = "cmux://auth-callback?cmux_auth_state=state-123";
    for (const challenge of ["short", `${CHALLENGE}x`, "%"]) {
      const response = await GET(signInRequest(nativeReturnTo, "handoff-nonce", undefined, undefined, challenge));
      expect(response.headers.get("location")).toBe("https://cmux.test/");
    }
    const plain = signInRequest(nativeReturnTo, "handoff-nonce");
    plain.nextUrl.searchParams.set("code_challenge_method", "plain");
    const plainResponse = await GET(new NextRequest(plain.nextUrl));
    expect(plainResponse.headers.get("location")).toBe("https://cmux.test/");
    expect(storedCodes.size).toBe(0);
    expect(defaultCreateSession).not.toHaveBeenCalled();
  });

  test("drops credential parameters the return target tries to carry", async () => {
    const nativeReturnTo =
      "cmux://auth-callback?cmux_auth_state=state-123&code=planted&stack_refresh=planted&stack_access=planted";

    const response = await handOff(signInRequest(nativeReturnTo, "handoff-nonce"));

    const callbackURL = new URL(response.headers.get("location")!);
    expect(callbackURL.searchParams.getAll("code")).toHaveLength(1);
    expect(callbackURL.searchParams.get("code")).not.toBe("planted");
    expect(callbackURL.searchParams.has("stack_refresh")).toBe(false);
    expect(callbackURL.searchParams.has("stack_access")).toBe(false);
  });

  test("a legacy request without a challenge needs a click, then mints its session", async () => {
    // Builds that predate PKCE keep working, but never without the click.
    const nativeReturnTo = "cmux://auth-callback?cmux_auth_state=state-123";

    const response = await GET(signInRequest(nativeReturnTo, "handoff-nonce", undefined, undefined, null));

    expect(response.status).toBe(200);
    expect(response.headers.get("location")).toBeNull();
    const html = await response.text();
    expectNoTokens(html);
    expect(defaultCreateSession).not.toHaveBeenCalled();

    const confirmed = await GET(confirmFromPage(html, response));
    expect(confirmed.status).toBe(307);
    expect(defaultCreateSession).toHaveBeenCalledWith({ expiresInMillis: 30 * 24 * 60 * 60 * 1000 });
    const callbackURL = new URL(confirmed.headers.get("location")!);
    expect(callbackURL.searchParams.get("cmux_auth_state")).toBe("state-123");
    expect(callbackURL.searchParams.get("stack_refresh")).toBe("minted-refresh");
    expect(storedCodes.size).toBe(0);
  });

  test("a forged confirmation nonce does not hand off", async () => {
    confirmCookie = "real-nonce";
    const request = signInRequest("cmux://auth-callback?cmux_auth_state=s", "x", undefined, undefined, null);
    request.nextUrl.searchParams.set("cmux_auth_confirm", "forged-nonce");

    const response = await GET(new NextRequest(request.nextUrl, { headers: { "accept-language": "en" } }));

    expect(response.status).toBe(200);
    expectNoTokens(await response.text());
    expect(defaultCreateSession).not.toHaveBeenCalled();
  });

  test("does not crash on malformed percent-encoded stack cookies", async () => {
    rawRefreshCookie = "%";
    rawAccessCookie = "%";
    getUserResponses = [null, null, null, null];
    const nativeReturnTo = "cmux://auth-callback?cmux_auth_state=state-123";
    const page = await GET(signInRequest(nativeReturnTo, "handoff-nonce", undefined, undefined, null));

    const response = await GET(confirmFromPage(await page.text(), page));

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://cmux.test/");
  });

  test("issues a code for an existing anonymous purchaser session", async () => {
    const createSession = mock(async () => ({
      getTokens: async () => ({ refreshToken: "anon-refresh", accessToken: "anon-access" }),
    }));
    getUserResponses = [null, { id: "anon-1", createSession }, null, { id: "anon-1", createSession }];

    const response = await handOff(signInRequest("cmux://auth-callback?cmux_auth_state=s", "handoff-nonce"));

    expect(getUser).toHaveBeenNthCalledWith(1, { or: "return-null" });
    expect(getUser).toHaveBeenNthCalledWith(2, { or: "anonymous-if-exists[deprecated]" });
    expect(createSession).not.toHaveBeenCalled();
    const code = new URL(response.headers.get("location")!).searchParams.get("code")!;
    expect(storedCodes.get(hashNativeSignInCode(code))?.userId).toBe("anon-1");
  });

  test("a failed user lookup answers the retry page, not home", async () => {
    getUserResponses = [new Error("Stack unavailable")];
    const request = signInRequest("cmux://auth-callback?cmux_auth_state=s", "handoff-nonce");

    const response = await GET(request);

    expect(response.status).toBe(503);
    expect(response.headers.get("location")).toBeNull();
    expect(await response.text()).toContain(`${request.nextUrl.pathname}`);
    expect(storedCodes.size).toBe(0);
  });

  test("answers a retry page when the code store is unavailable", async () => {
    const failing = makeAfterSignInHandler({
      projectId: "test-project",
      stackServerApp: { getUser },
      nativeSignInCodeStore: {
        insert: async () => {
          throw new Error("database unavailable");
        },
        consume: async () => null,
      },
      getCookieStore: async () => ({
        get: (name: string) => (name === CONFIRM_COOKIE && confirmCookie ? { value: confirmCookie } : undefined),
        getAll: () => [],
      }),
    });

    const page = await failing(signInRequest("cmux://auth-callback?cmux_auth_state=s", "handoff-nonce"));
    expect(page.status).toBe(200);
    const response = await failing(confirmFromPage(await page.text(), page));

    expect(response.status).toBe(503);
    expect(response.headers.get("location")).toBeNull();
    expect(defaultCreateSession).not.toHaveBeenCalled();
  });

  test("promotes a verified anonymous account before minting handoff tokens", async () => {
    rawRefreshCookie = "";
    rawAccessCookie = "";
    const createSession = mock(async () => ({
      getTokens: async () => ({
        refreshToken: "promoted-refresh",
        accessToken: "promoted-access",
      }),
    }));
    const user = {
      id: "anonymous-verified",
      primaryEmail: "buyer@example.com",
      primaryEmailVerified: true,
      isAnonymous: true,
      createSession,
    };
    getUserResponses = [null, user];

    const response = await GET(
      signInRequest("cmux://auth-callback", "unused"),
    );

    expect(promoteVerifiedAnonymousUser).toHaveBeenCalledWith(
      "anonymous-verified",
      "buyer@example.com",
    );
    expect(claimVerifiedBilling).toHaveBeenCalledWith(
      "anonymous-verified",
      "buyer@example.com",
    );
    expect(applyAdminGrants).toHaveBeenCalledWith(
      "anonymous-verified",
      "buyer@example.com",
    );
    // Promotion runs at the callback; the session waits for the app's redemption.
    expect(createSession).not.toHaveBeenCalled();
    expect(response.status).toBe(200);
    expectNoTokens(await response.text());
  });

  test("resolves pending billing claims for a verified existing account", async () => {
    const createSession = mock(async () => ({
      getTokens: async () => ({
        refreshToken: "verified-refresh",
        accessToken: "verified-access",
      }),
    }));
    const user = {
      id: "verified-account",
      primaryEmail: "buyer@example.com",
      primaryEmailVerified: true,
      isAnonymous: false,
      createSession,
    };
    getUserResponses = [user];

    const response = await GET(
      signInRequest("cmux://auth-callback", "unused"),
    );

    expect(claimVerifiedBilling).toHaveBeenCalledWith(
      "verified-account",
      "buyer@example.com",
    );
    expect(applyAdminGrants).toHaveBeenCalledWith(
      "verified-account",
      "buyer@example.com",
    );
    expect(response.status).toBe(200);
    expect(createSession).not.toHaveBeenCalled();
  });

  test("does not mint a session when anonymous promotion fails", async () => {
    rawRefreshCookie = "";
    rawAccessCookie = "";
    const createSession = mock(async () => ({
      getTokens: async () => ({
        refreshToken: "must-not-be-issued",
        accessToken: "must-not-be-issued",
      }),
    }));
    const user = {
      id: "anonymous-promotion-failed",
      primaryEmail: "buyer@example.com",
      primaryEmailVerified: true,
      isAnonymous: true,
      createSession,
    };
    getUserResponses = [null, user];
    promotionShouldFail = true;

    const response = await GET(
      signInRequest("cmux://auth-callback", "unused"),
    );

    expect(response.status).toBe(503);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("retry-after")).toBe("0");
    expect(createSession).not.toHaveBeenCalled();
    expect(await response.text()).toContain(
      "If we found an account, check your email for next steps",
    );
  });

  test("a Stack throttle answers a localized retry page that resumes the same callback", async () => {
    const throttled = Object.assign(new Error("Stack Auth rate limited"), { status: 429 });
    for (const [language, title] of [["en", "Sign-in is busy"], ["ja", "サインインが混み合っています"]] as const) {
      getUserResponses = [throttled];
      const request = signInRequest("cmux://auth-callback", "nonce-1");
      request.headers.set("accept-language", language);
      const response = await GET(request);

      expect(response.status).toBe(503);
      expect(response.headers.get("retry-after")).toBe("30");
      expect(response.headers.get("cache-control")).toBe("no-store");
      const html = await response.text();
      expect(html).toContain(title);
      const retry = html.match(/<a href="([^"]+)">/)?.[1]?.replaceAll("&amp;", "&");
      expect(retry).toBe(`${request.nextUrl.pathname}${request.nextUrl.search}`);
      // Nothing ran against the old cookie session.
      expect(promoteVerifiedAnonymousUser).not.toHaveBeenCalled();
      expect(claimVerifiedBilling).not.toHaveBeenCalled();
      expect(response.headers.get("location")).toBeNull();
    }
  });

  test("accepts only signed tagged purchase callbacks on the deployed host", async () => {
    const previousSecret = process.env.CMUX_APP_PRICING_RELAY_SECRET;
    process.env.CMUX_APP_PRICING_RELAY_SECRET =
      "pricing-relay-test-secret-with-at-least-32-bytes";
    try {
      const afterSignIn = appPricingNativeReturnURL(
        new URL("/handler/after-sign-in", "https://cmux.test"),
        "cmux-dev-test://auth-callback",
        "cs_123",
      );
      const response = await GET(new NextRequest(afterSignIn));

      // A purchase return has no challenge: the legacy hand-off, behind a click.
      expect(response.status).toBe(200);
      const html = await response.text();
      expectNoTokens(html);
      const confirmURL = new URL(returnHref(html), "https://cmux.test");
      expect(confirmURL.pathname).toBe("/handler/after-sign-in");
      expect(confirmURL.searchParams.get("native_app_return_to")).toBe("cmux-dev-test://auth-callback");
      expect(confirmURL.searchParams.get("cmux_checkout_session")).toBe("cs_123");
      const confirmed = await GET(confirmFromPage(html, response));
      expect(new URL(confirmed.headers.get("location")!).protocol).toBe("cmux-dev-test:");
      const switchURL = new URL(switchAccountHref(html), "https://cmux.test");
      const nativeSignInTarget = new URL(
        switchURL.searchParams.get("after_auth_return_to")!,
        "https://cmux.test",
      );
      const preservedAfterSignIn = new URL(
        nativeSignInTarget.searchParams.get("after_auth_return_to")!,
        "https://cmux.test",
      );
      expect(preservedAfterSignIn.searchParams.get("cmux_checkout_session")).toBe(
        "cs_123",
      );
      expect(preservedAfterSignIn.searchParams.get("cmux_native_return_signature"))
        .toMatch(/^[a-f0-9]{64}$/);

      afterSignIn.searchParams.set(
        "native_app_return_to",
        "cmux-dev-other://auth-callback",
      );
      const tamperedResponse = await GET(new NextRequest(afterSignIn));
      expect(tamperedResponse.status).toBe(307);
      expect(tamperedResponse.headers.get("location")).toBe("https://cmux.test/");
    } finally {
      if (previousSecret === undefined) {
        delete process.env.CMUX_APP_PRICING_RELAY_SECRET;
      } else {
        process.env.CMUX_APP_PRICING_RELAY_SECRET = previousSecret;
      }
    }
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
    expect(setCookie).toContain("HttpOnly");
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

  const publicationTransaction = "tx_0123456789abcdefghijklmnopqrstuvwxyz";
  const publicationState = "st_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

  function publicationSignIn(access: string): string {
    const afterSignIn = `/handler/after-sign-in?after_auth_return_to=${encodeURIComponent(access)}`;
    return `/handler/sign-in?after_auth_return_to=${encodeURIComponent(afterSignIn)}`;
  }

  test("signs out and redirects into sign-in for a protected Cloud VM domain transaction", async () => {
    const access = `/cloud/access?transaction=${publicationTransaction}&state=${publicationState}`;
    const signIn = publicationSignIn(access);

    const response = await GET(switchRequest(signIn));

    expect(signOut).toHaveBeenCalledWith({ redirectUrl: `https://cmux.test${signIn}` });
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(`https://cmux.test${signIn}`);
    const setCookie = response.headers.get("set-cookie");
    expect(setCookie).toMatch(/(?:^|,\s*)stack-access=;[^,]*Max-Age=0/i);
    expect(setCookie).toContain("stack-refresh-test-project=;");
  });

  test("signs out and redirects into sign-in for CLI authorization", async () => {
    const confirmation = "/handler/cli-auth-confirm?login_code=test-login-code";
    const signIn = `/handler/sign-in?after_auth_return_to=${encodeURIComponent(confirmation)}`;

    const response = await GET(switchRequest(signIn));

    expect(signOut).toHaveBeenCalledWith({ redirectUrl: `https://cmux.test${signIn}` });
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(`https://cmux.test${signIn}`);
    expect(response.headers.get("set-cookie")).toMatch(
      /(?:^|,\s*)stack-access=;[^,]*Max-Age=0/i,
    );
  });

  test("rejects CLI sign-in targets that are not one exact authorization code", async () => {
    const malformedConfirmations = [
      "/handler/cli-auth-confirm",
      "/handler/cli-auth-confirm?login_code=test-login-code&next=%2Fdocs",
      "/handler/cli-auth-confirm?login_code=not.valid",
      "https://evil.test/handler/cli-auth-confirm?login_code=test-login-code",
    ];

    for (const confirmation of malformedConfirmations) {
      const signIn = `/handler/sign-in?after_auth_return_to=${encodeURIComponent(confirmation)}`;
      const response = await GET(switchRequest(signIn));
      expect(signOut).not.toHaveBeenCalled();
      expect(response.status).toBe(307);
      expect(response.headers.get("location")).toBe("https://cmux.test/");
    }
  });

  test("rejects Cloud VM access targets that are not exactly an opaque transaction", async () => {
    const malformed = [
      `/cloud/access?transaction=short&state=${publicationState}`,
      `/cloud/access?transaction=${publicationTransaction}`,
      `/cloud/access?transaction=${publicationTransaction}&state=${publicationState}&next=%2Fdocs`,
      `/cloud/other?transaction=${publicationTransaction}&state=${publicationState}`,
      `https://evil.test/cloud/access?transaction=${publicationTransaction}&state=${publicationState}`,
    ];

    for (const access of malformed) {
      const response = await GET(switchRequest(publicationSignIn(access)));
      expect(signOut).not.toHaveBeenCalled();
      expect(response.status).toBe(307);
      expect(response.headers.get("location")).toBe("https://cmux.test/");
    }

    const extraSignInParam = `/handler/sign-in?after_auth_return_to=${encodeURIComponent(
      `/handler/after-sign-in?after_auth_return_to=${encodeURIComponent(`/cloud/access?transaction=${publicationTransaction}&state=${publicationState}`)}`,
    )}&prompt=none`;
    const response = await GET(switchRequest(extraSignInParam));
    expect(signOut).not.toHaveBeenCalled();
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

  test("rejects same-site attempts to force sign-out", async () => {
    const afterSignIn = "/handler/after-sign-in?native_app_return_to=cmux%3A%2F%2Fauth-callback%3Fcmux_auth_state%3Dstate-123";
    const nativeSignIn = `/handler/native-sign-in?after_auth_return_to=${encodeURIComponent(afterSignIn)}`;

    const response = await GET(switchRequest(nativeSignIn, { "sec-fetch-site": "same-site" }));

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
