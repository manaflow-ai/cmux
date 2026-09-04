import type { NextRequest, NextResponse } from "next/server";

const OTP_NONCE_COOKIE_BASE = "cmux-otp-nonce";
const OTP_NONCE_MAX_AGE_SECONDS = 15 * 60;

/**
 * The nonce is the half of a one-time code that never leaves this browser; the
 * emailed six characters are the half the visitor proves they received. Keeping
 * it in an httpOnly cookie rather than the query string means it stays out of
 * history, referrers, and shared links.
 */
export function otpNonceCookieName(secure: boolean): string {
  return secure ? `__Host-${OTP_NONCE_COOKIE_BASE}` : OTP_NONCE_COOKIE_BASE;
}

export function setOTPNonceCookie(
  response: NextResponse,
  nonce: string,
  secure: boolean,
): void {
  response.cookies.set(otpNonceCookieName(secure), nonce, {
    httpOnly: true,
    maxAge: OTP_NONCE_MAX_AGE_SECONDS,
    path: "/",
    sameSite: "lax",
    secure,
  });
}

export function readOTPNonce(
  request: NextRequest,
  secure: boolean,
): string | null {
  return request.cookies.get(otpNonceCookieName(secure))?.value ?? null;
}

export function clearOTPNonceCookie(
  response: NextResponse,
  secure: boolean,
): void {
  response.cookies.set(otpNonceCookieName(secure), "", {
    httpOnly: true,
    maxAge: 0,
    path: "/",
    sameSite: "lax",
    secure,
  });
}
