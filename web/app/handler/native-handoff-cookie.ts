import type { NextRequest, NextResponse } from "next/server";

export const NATIVE_HANDOFF_COOKIE_NAME = "cmux-native-auth-handoff";
export const NATIVE_HANDOFF_QUERY_PARAM = "cmux_auth_handoff";

const NATIVE_HANDOFF_COOKIE_PATH = "/handler/after-sign-in";
const NATIVE_HANDOFF_TTL_SECONDS = 10 * 60;

function writeNativeHandoffCookie(
  response: NextResponse,
  request: NextRequest,
  value: string,
  maxAge: number
): void {
  response.cookies.set(NATIVE_HANDOFF_COOKIE_NAME, value, {
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
  writeNativeHandoffCookie(response, request, nonce, NATIVE_HANDOFF_TTL_SECONDS);
}

export function clearNativeHandoffCookie(
  response: NextResponse,
  request: NextRequest
): void {
  writeNativeHandoffCookie(response, request, "", 0);
}
