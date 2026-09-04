import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";

import { authErrorKeyForCode, parseAuthErrorKey } from
  "../services/auth/hexclave/errorCodes";
import { isSameOriginFormPost, looksLikeEmail } from
  "../services/auth/hexclave/formRequest";
import { oauthAuthorizeURL } from "../services/auth/hexclave/auth";
import {
  clearOAuthHandoffCookie,
  createOAuthHandoff,
  oauthHandoffCookieName,
  readOAuthHandoff,
  setOAuthHandoffCookie,
} from "../services/auth/hexclave/oauthState";
import { safeReturnToPath } from "../services/auth/hexclave/returnTo";
import { NextResponse } from "next/server";

const CONFIG = {
  apiBaseURL: "https://api.hexclave.test",
  projectId: "project-1",
  publishableClientKey: "pck_test",
};

function formPost(
  url: string,
  body: Record<string, string>,
  headers: Record<string, string>,
): NextRequest {
  return new NextRequest(url, {
    method: "POST",
    headers,
    body: new URLSearchParams(body),
  });
}

describe("return-to validation", () => {
  test("keeps a same-origin path", () => {
    expect(safeReturnToPath("/dashboard?tab=1")).toBe("/dashboard?tab=1");
  });

  test("rejects every shape that could leave the origin", () => {
    for (const hostile of [
      "https://evil.test/steal",
      "//evil.test/steal",
      "/\\evil.test",
      "\\\\evil.test",
      "javascript:alert(1)",
    ]) {
      expect(safeReturnToPath(hostile)).toBe("/handler/after-sign-in");
    }
  });

  test("falls back when the caller names no destination", () => {
    expect(safeReturnToPath(null)).toBe("/handler/after-sign-in");
    expect(safeReturnToPath("")).toBe("/handler/after-sign-in");
  });
});

describe("auth error mapping", () => {
  test("translates the codes the product branches on", () => {
    expect(authErrorKeyForCode("EMAIL_PASSWORD_MISMATCH"))
      .toBe("invalidCredentials");
    expect(authErrorKeyForCode("USER_EMAIL_ALREADY_EXISTS")).toBe("emailTaken");
    expect(authErrorKeyForCode("VERIFICATION_CODE_EXPIRED")).toBe("expiredCode");
  });

  test("an unknown code reads as an outage unless the site says otherwise", () => {
    expect(authErrorKeyForCode("SOMETHING_NEW")).toBe("unexpected");
    expect(authErrorKeyForCode("SCHEMA_ERROR", "invalidCode"))
      .toBe("invalidCode");
  });

  test("a tampered query key never reaches the message catalog", () => {
    expect(parseAuthErrorKey("weakPassword")).toBe("weakPassword");
    expect(parseAuthErrorKey("<script>")).toBe("unexpected");
    expect(parseAuthErrorKey(null)).toBeNull();
  });
});

describe("same-origin form guard", () => {
  const origin = "https://cmux.test";

  test("accepts a submission from our own page", () => {
    const request = formPost(`${origin}/handler/sign-in/submit`, {}, {
      origin,
      "sec-fetch-site": "same-origin",
    });
    expect(isSameOriginFormPost(request, origin)).toBe(true);
  });

  test("rejects a cross-site submission", () => {
    const request = formPost(`${origin}/handler/sign-in/submit`, {}, {
      origin: "https://evil.test",
      "sec-fetch-site": "cross-site",
    });
    expect(isSameOriginFormPost(request, origin)).toBe(false);
  });

  test("rejects a mismatched Origin even when the site header is absent", () => {
    const request = formPost(`${origin}/handler/sign-in/submit`, {}, {
      origin: "https://evil.test",
    });
    expect(isSameOriginFormPost(request, origin)).toBe(false);
  });

  test("rejects a request that carries neither signal", () => {
    const request = formPost(`${origin}/handler/sign-in/submit`, {}, {});
    expect(isSameOriginFormPost(request, origin)).toBe(false);
  });
});

describe("email shape check", () => {
  test("accepts an ordinary address and rejects obvious junk", () => {
    expect(looksLikeEmail("a@b.co")).toBe(true);
    expect(looksLikeEmail("no-at-sign")).toBe(false);
    expect(looksLikeEmail("two@@at.co")).toBe(false);
    expect(looksLikeEmail(`${"a".repeat(250)}@b.co`)).toBe(false);
  });
});

describe("outer OAuth authorize URL", () => {
  test("carries the PKCE challenge and this app's callback", () => {
    const url = new URL(oauthAuthorizeURL(CONFIG, {
      provider: "github",
      redirectURI: "https://cmux.test/handler/oauth-callback",
      errorRedirectURL: "https://cmux.test/handler/auth-error",
      state: "state-1",
      codeChallenge: "challenge-1",
    }));

    expect(url.origin + url.pathname)
      .toBe("https://api.hexclave.test/api/v1/auth/oauth/authorize/github");
    expect(url.searchParams.get("client_id")).toBe("project-1");
    expect(url.searchParams.get("code_challenge_method")).toBe("S256");
    expect(url.searchParams.get("code_challenge")).toBe("challenge-1");
    expect(url.searchParams.get("state")).toBe("state-1");
    expect(url.searchParams.get("redirect_uri"))
      .toBe("https://cmux.test/handler/oauth-callback");
  });
});

describe("OAuth handoff cookie", () => {
  test("round-trips the verifier only for the matching state", async () => {
    const handoff = await createOAuthHandoff("/dashboard");
    const response = NextResponse.next();
    setOAuthHandoffCookie(response, handoff, true);

    const cookie = response.cookies.get(oauthHandoffCookieName(true));
    expect(cookie?.value).toBeTruthy();
    // The verifier must never be readable by a script on the page.
    expect(cookie?.httpOnly).toBe(true);

    const request = new NextRequest("https://cmux.test/handler/oauth-callback", {
      headers: { cookie: `${oauthHandoffCookieName(true)}=${cookie?.value}` },
    });

    expect(readOAuthHandoff(request, handoff.state, true)?.codeVerifier)
      .toBe(handoff.codeVerifier);
    expect(readOAuthHandoff(request, "someone-elses-state", true)).toBeNull();
  });

  test("a fresh attempt never reuses a challenge", async () => {
    const first = await createOAuthHandoff("/dashboard");
    const second = await createOAuthHandoff("/dashboard");
    expect(first.codeVerifier).not.toBe(second.codeVerifier);
    expect(first.state).not.toBe(second.state);
    expect(first.codeChallenge).not.toBe(second.codeChallenge);
  });

  test("clearing removes the cookie", () => {
    const response = NextResponse.next();
    clearOAuthHandoffCookie(response, true);
    expect(response.cookies.get(oauthHandoffCookieName(true))?.value).toBe("");
  });
});

describe("emailed single-use codes are never spent by a GET", () => {
  test("the magic-link and verification callbacks expose no GET handler", async () => {
    const magicLink = await import(
      "../app/handler/magic-link-callback/submit/route"
    );
    const verification = await import(
      "../app/handler/email-verification/submit/route"
    );

    // A mail scanner or link preview fetches these URLs before the person
    // does. Only the confirmation POST may redeem the code.
    expect("GET" in magicLink).toBe(false);
    expect("GET" in verification).toBe(false);
    expect(typeof magicLink.POST).toBe("function");
    expect(typeof verification.POST).toBe("function");
  });
});
