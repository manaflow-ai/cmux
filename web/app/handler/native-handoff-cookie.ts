import type { NextRequest, NextResponse } from "next/server";

export const NATIVE_HANDOFF_COOKIE_NAME = "cmux-native-auth-handoff";
export const NATIVE_HANDOFF_QUERY_PARAM = "cmux_auth_handoff";

/**
 * Set by the after-sign-in confirmation page and echoed by its button, so a
 * hand-off that needs a click proceeds only from that page's own link.
 */
export const NATIVE_CONFIRM_COOKIE_NAME = "cmux-native-auth-confirm";
export const NATIVE_CONFIRM_QUERY_PARAM = "cmux_auth_confirm";

const NATIVE_HANDOFF_COOKIE_PATH = "/handler/after-sign-in";
const NATIVE_HANDOFF_TTL_SECONDS = 10 * 60;

function writeNativeCookie(
  response: NextResponse,
  request: NextRequest,
  name: string,
  value: string,
  maxAge: number
): void {
  response.cookies.set(name, value, {
    httpOnly: true,
    maxAge,
    path: NATIVE_HANDOFF_COOKIE_PATH,
    sameSite: "lax",
    secure: request.nextUrl.protocol === "https:",
  });
}

export function issueNativeHandoffCookie(
  response: NextResponse,
  request: NextRequest,
  nonce: string
): void {
  writeNativeCookie(response, request, NATIVE_HANDOFF_COOKIE_NAME, nonce, NATIVE_HANDOFF_TTL_SECONDS);
}

export function clearNativeHandoffCookie(
  response: NextResponse,
  request: NextRequest
): void {
  writeNativeCookie(response, request, NATIVE_HANDOFF_COOKIE_NAME, "", 0);
}

export function issueNativeConfirmCookie(
  response: NextResponse,
  request: NextRequest,
  nonce: string
): void {
  writeNativeCookie(response, request, NATIVE_CONFIRM_COOKIE_NAME, nonce, NATIVE_HANDOFF_TTL_SECONDS);
}

export function clearNativeConfirmCookie(
  response: NextResponse,
  request: NextRequest
): void {
  writeNativeCookie(response, request, NATIVE_CONFIRM_COOKIE_NAME, "", 0);
}
