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

function requestProtocol(request: NextRequest): "http" | "https" {
  const forwardedProto = firstHeaderValue(request.headers.get("x-forwarded-proto"))?.toLowerCase();
  if (forwardedProto === "http" || forwardedProto === "https") return forwardedProto;
  return request.nextUrl.protocol === "https:" ? "https" : "http";
}

function hostWithoutPort(value: string): string {
  if (value.startsWith("[") && value.includes("]")) {
    return value.slice(1, value.indexOf("]")).toLowerCase();
  }
  return value.split(":")[0]?.toLowerCase() ?? "";
}

function isLoopbackHost(host: string): boolean {
  return host === "localhost" || host === "127.0.0.1" || host === "::1";
}

function isPrivateIPv4Host(host: string): boolean {
  const parts = host.split(".").map((part) => Number(part));
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return false;
  }
  const [first, second] = parts;
  return first === 10
    || (first === 172 && second >= 16 && second <= 31)
    || (first === 192 && second === 168)
    || (first === 169 && second === 254);
}

function isDevNetworkHost(host: string): boolean {
  return isLoopbackHost(host) || isPrivateIPv4Host(host) || host.endsWith(".local");
}

function configuredPublicOrigins(): string[] {
  const values = [
    process.env.CMUX_PUBLIC_ORIGIN,
    process.env.NEXT_PUBLIC_CMUX_PUBLIC_ORIGIN,
  ];
  const origins: string[] = [];
  for (const value of values) {
    for (const raw of value?.split(/[\s,]+/) ?? []) {
      try {
        if (raw) origins.push(new URL(raw).origin);
      } catch {}
    }
  }
  return origins;
}

function requestOriginCandidates(request: NextRequest): Set<string> {
  const origins = new Set<string>([request.nextUrl.origin]);
  for (const origin of configuredPublicOrigins()) origins.add(origin);

  const host = firstHeaderValue(request.headers.get("host"));
  const requestHost = hostWithoutPort(request.nextUrl.host);
  const hostHeaderHost = host ? hostWithoutPort(host) : "";
  const allowHostDerivedDevOrigin = hostHeaderHost
    && isDevNetworkHost(hostHeaderHost)
    && isDevNetworkHost(requestHost)
    && process.env.NODE_ENV !== "production";
  if (host && allowHostDerivedDevOrigin) {
    try {
      origins.add(new URL(`${requestProtocol(request)}://${host}`).origin);
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
      secure: requestProtocol(request) === "https",
    });
  }
  return response;
}
