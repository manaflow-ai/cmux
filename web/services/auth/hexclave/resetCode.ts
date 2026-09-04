import type { NextResponse } from "next/server";

const RESET_CODE_COOKIE_BASE = "cmux-reset-code";
const RESET_CODE_MAX_AGE_SECONDS = 15 * 60;

/** The API defines a reset code as exactly 45 URL-safe characters. */
export function isResetCodeShaped(code: string): boolean {
  return /^[A-Za-z0-9_-]{45}$/u.test(code);
}

/**
 * Holds the reset credential for the few minutes between opening the emailed
 * link and choosing a password.
 *
 * The link puts the code in the address bar once, and this cookie is what lets
 * the next request take it back out: the form page, its retries, and its
 * failure messages all run on a URL with no credential in it, so the code
 * stays out of history, `Referer`, and anything the visitor pastes.
 */
export function resetCodeCookieName(secure: boolean): string {
  return secure ? `__Host-${RESET_CODE_COOKIE_BASE}` : RESET_CODE_COOKIE_BASE;
}

export function setResetCodeCookie(
  response: NextResponse,
  code: string,
  secure: boolean,
): void {
  response.cookies.set(resetCodeCookieName(secure), code, {
    httpOnly: true,
    maxAge: RESET_CODE_MAX_AGE_SECONDS,
    path: "/",
    sameSite: "lax",
    secure,
  });
}

/**
 * Reads the cookie under either name. A reader does not know whether the write
 * happened over HTTPS, and guessing wrong would look like an expired link.
 */
export function readResetCodeCookie(cookies: {
  get(name: string): { value: string } | undefined;
}): string | null {
  return cookies.get(resetCodeCookieName(true))?.value ??
    cookies.get(resetCodeCookieName(false))?.value ??
    null;
}

export function clearResetCodeCookie(
  response: NextResponse,
  secure: boolean,
): void {
  response.cookies.set(resetCodeCookieName(secure), "", {
    httpOnly: true,
    maxAge: 0,
    path: "/",
    sameSite: "lax",
    secure,
  });
}
