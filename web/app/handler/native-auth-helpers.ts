import { NextRequest } from "next/server";

const NATIVE_SCHEMES = new Set(["cmux", "cmux-nightly"]);

function firstHeaderValue(value: string | null): string | null {
  return value?.split(",")[0]?.trim() || null;
}

function requestHostCandidates(request: NextRequest): Set<string> {
  const hosts = new Set<string>();
  for (const value of [
    request.headers.get("host"),
    request.headers.get("x-forwarded-host"),
    request.nextUrl.host,
  ]) {
    const host = firstHeaderValue(value)?.split(":")[0]?.toLowerCase();
    if (host) hosts.add(host);
  }
  return hosts;
}

function isLoopbackHost(host: string): boolean {
  return host === "localhost" || host === "127.0.0.1" || host === "::1" || host === "[::1]";
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

export function isLocalRequest(request: NextRequest): boolean {
  for (const host of requestHostCandidates(request)) {
    if (isLoopbackHost(host)) return true;
  }
  return false;
}

function isTrustedDevRequest(request: NextRequest): boolean {
  if (isLocalRequest(request)) return true;
  if (process.env.NODE_ENV === "production") return false;
  for (const host of requestHostCandidates(request)) {
    if (isPrivateIPv4Host(host) || host.endsWith(".local")) return true;
  }
  return false;
}

function localAllowedNativeSchemes(): Set<string> {
  const values = [
    process.env.CMUX_AUTH_CALLBACK_SCHEME,
    process.env.CMUX_ALLOWED_NATIVE_CALLBACK_SCHEMES,
    process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES,
  ];
  const schemes = new Set<string>();
  for (const value of values) {
    for (const raw of value?.split(/[\s,]+/) ?? []) {
      const scheme = raw.trim().replace(/:\/\/.*$/, "").replace(/:$/, "");
      if (/^cmux-dev-[a-z0-9-]+$/.test(scheme)) schemes.add(scheme);
    }
  }
  return schemes;
}

export function isAllowedNativeReturnTo(href: string, request: NextRequest): boolean {
  try {
    const url = new URL(href);
    if (url.hostname !== "auth-callback") return false;
    if (url.pathname !== "" && url.pathname !== "/") return false;
    const scheme = url.protocol.replace(":", "");
    if (NATIVE_SCHEMES.has(scheme)) return true;
    if (scheme === "cmux-dev") return isLocalRequest(request);
    return isTrustedDevRequest(request) && localAllowedNativeSchemes().has(scheme);
  } catch {
    return false;
  }
}
