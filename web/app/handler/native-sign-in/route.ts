import { randomUUID } from "crypto";
import { NextRequest, NextResponse } from "next/server";

export const dynamic = "force-dynamic";

const NATIVE_HANDOFF_COOKIE = "cmux-native-auth-handoff";
const NATIVE_HANDOFF_PARAM = "cmux_auth_handoff";

function canSetAutoHandoff(request: NextRequest): boolean {
  const fetchSite = request.headers.get("sec-fetch-site");
  return fetchSite === null || fetchSite === "none" || fetchSite === "same-origin" || fetchSite === "same-site";
}

function firstHeaderValue(value: string | null): string | null {
  return value?.split(",")[0]?.trim() || null;
}

function requestProtocol(request: NextRequest): string {
  return firstHeaderValue(request.headers.get("x-forwarded-proto"))
    ?? request.nextUrl.protocol.replace(/:$/, "")
    ?? "http";
}

function requestOriginCandidates(request: NextRequest): Set<string> {
  const origins = new Set<string>([request.nextUrl.origin]);
  const protocol = requestProtocol(request);
  const hostValues = [
    firstHeaderValue(request.headers.get("host")),
    firstHeaderValue(request.headers.get("x-forwarded-host")),
  ];
  for (const host of hostValues) {
    if (!host) continue;
    try {
      origins.add(new URL(`${protocol}://${host}`).origin);
    } catch {}
  }
  return origins;
}

function sameOriginURL(value: string, request: NextRequest): URL | null {
  try {
    const url = new URL(value, request.nextUrl.origin);
    return requestOriginCandidates(request).has(url.origin) ? url : null;
  } catch {
    return null;
  }
}

export function GET(request: NextRequest) {
  const afterAuthReturnTo = request.nextUrl.searchParams.get("after_auth_return_to");
  if (!afterAuthReturnTo) return NextResponse.redirect(new URL("/handler/sign-in", request.url));

  const afterSignInURL = sameOriginURL(afterAuthReturnTo, request);
  if (!afterSignInURL || afterSignInURL.pathname !== "/handler/after-sign-in") {
    return NextResponse.redirect(new URL("/", request.url));
  }

  const nativeReturnTo = afterSignInURL.searchParams.get("native_app_return_to");
  const shouldSetHandoff = canSetAutoHandoff(request) && nativeReturnTo?.includes("cmux_auth_state") === true;
  let nonce: string | null = null;
  if (shouldSetHandoff) {
    nonce = randomUUID();
    afterSignInURL.searchParams.set(NATIVE_HANDOFF_PARAM, nonce);
  }

  const stackSignInURL = new URL("/handler/sign-in", afterSignInURL.origin);
  stackSignInURL.searchParams.set("after_auth_return_to", afterSignInURL.toString());
  const response = NextResponse.redirect(stackSignInURL);
  if (nonce) {
    response.cookies.set(NATIVE_HANDOFF_COOKIE, nonce, {
      httpOnly: true,
      maxAge: 10 * 60,
      path: "/handler/after-sign-in",
      sameSite: "lax",
      secure: request.nextUrl.protocol === "https:",
    });
  }
  return response;
}
