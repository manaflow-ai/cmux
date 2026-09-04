import type { NextRequest, NextResponse } from "next/server";

const OAUTH_COOKIE_BASE = "cmux-oauth-handoff";
const OAUTH_COOKIE_MAX_AGE_SECONDS = 10 * 60;

export type HexclaveOAuthHandoff = {
  readonly state: string;
  readonly codeVerifier: string;
  /** Same-origin path to return to once the session exists. */
  readonly returnTo: string;
};

export function oauthHandoffCookieName(secure: boolean): string {
  return secure ? `__Host-${OAUTH_COOKIE_BASE}` : OAUTH_COOKIE_BASE;
}

/**
 * Creates the PKCE pair for one outer-OAuth attempt.
 *
 * cmux keeps the verifier in an httpOnly cookie rather than the localStorage
 * entry the browser SDK uses, so a script on the page can never read it and
 * the sign-in page needs no JavaScript at all.
 */
export async function createOAuthHandoff(
  returnTo: string,
): Promise<HexclaveOAuthHandoff & { readonly codeChallenge: string }> {
  const codeVerifier = randomURLSafeString(64);
  const state = randomURLSafeString(32);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(codeVerifier),
  );
  return {
    state,
    codeVerifier,
    returnTo,
    codeChallenge: base64URL(new Uint8Array(digest)),
  };
}

export function setOAuthHandoffCookie(
  response: NextResponse,
  handoff: HexclaveOAuthHandoff,
  secure: boolean,
): void {
  response.cookies.set(
    oauthHandoffCookieName(secure),
    JSON.stringify(handoff),
    {
      httpOnly: true,
      maxAge: OAUTH_COOKIE_MAX_AGE_SECONDS,
      path: "/",
      sameSite: "lax",
      secure,
    },
  );
}

/**
 * Reads and validates the handoff for a returning callback. The state
 * comparison is what stops an attacker from replaying their own authorization
 * code into this browser.
 */
export function readOAuthHandoff(
  request: NextRequest,
  expectedState: string,
  secure: boolean,
): HexclaveOAuthHandoff | null {
  const raw = request.cookies.get(oauthHandoffCookieName(secure))?.value;
  if (!raw) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const handoff = parsed as Partial<HexclaveOAuthHandoff>;
  if (
    typeof handoff.state !== "string" ||
    typeof handoff.codeVerifier !== "string" ||
    typeof handoff.returnTo !== "string"
  ) {
    return null;
  }
  if (!timingSafeEquals(handoff.state, expectedState)) return null;
  return {
    state: handoff.state,
    codeVerifier: handoff.codeVerifier,
    returnTo: handoff.returnTo,
  };
}

export function clearOAuthHandoffCookie(
  response: NextResponse,
  secure: boolean,
): void {
  response.cookies.set(oauthHandoffCookieName(secure), "", {
    httpOnly: true,
    maxAge: 0,
    path: "/",
    sameSite: "lax",
    secure,
  });
}

function randomURLSafeString(byteLength: number): string {
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);
  return base64URL(bytes);
}

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=+$/u, "");
}

/** Constant-time comparison so a mismatched state leaks no timing signal. */
function timingSafeEquals(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}
