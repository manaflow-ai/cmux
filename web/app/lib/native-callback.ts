import type { NextRequest } from "next/server";

export const DEFAULT_NATIVE_CALLBACK_SCHEME = "cmux";
export const NATIVE_CALLBACK_HOST = "auth-callback";

const NATIVE_SCHEMES = new Set([DEFAULT_NATIVE_CALLBACK_SCHEME, "cmux-nightly"]);

export function nativeCallbackHrefForScheme(scheme: string): string {
  return `${scheme}://${NATIVE_CALLBACK_HOST}`;
}

export function validatedNativeCallbackScheme(
  rawScheme: string | null,
  request: NextRequest,
): string {
  const scheme = rawScheme?.trim().toLowerCase() ?? "";
  if (scheme && isAllowedNativeScheme(scheme, request)) return scheme;
  return DEFAULT_NATIVE_CALLBACK_SCHEME;
}

export function trustedNativeCallbackScheme(
  rawScheme: string | null | undefined,
): string | null {
  const scheme = rawScheme?.trim().toLowerCase() ?? "";
  if (NATIVE_SCHEMES.has(scheme) || scheme === "cmux-dev") return scheme;
  return /^cmux-dev-[a-z0-9-]+$/.test(scheme) ? scheme : null;
}

export function isAllowedNativeReturnTo(
  href: string,
  request: NextRequest,
): boolean {
  try {
    const url = new URL(href);
    if (url.hostname !== NATIVE_CALLBACK_HOST) return false;
    if (url.pathname !== "" && url.pathname !== "/") return false;
    return isAllowedNativeScheme(url.protocol.replace(":", ""), request);
  } catch {
    return false;
  }
}

export 
const LOOPBACK_HOSTS = new Set(["127.0.0.1", "::1", "localhost"]);
/**
 * Loopback HTTP/HTTPS callbacks for CLI/TUI sign-in flows. Unlike native
 * scheme callbacks these point at a listener on the signing user own
 * machine, so they are only honored together with a verified handoff nonce
 * (enforced at the after-sign-in call site). The path is pinned to the
 * native callback host segment to keep the accepted target shape identical.
 */
export function isAllowedLoopbackReturnTo(href: string): boolean {
  try {
    const url = new URL(href);
    if (url.protocol !== "http:" && url.protocol !== "https:") return false;
    if (!LOOPBACK_HOSTS.has(url.hostname.toLowerCase())) return false;
    return url.pathname === "/" + NATIVE_CALLBACK_HOST;
  } catch {
    return false;
  }
}

function isAllowedNativeScheme(
  scheme: string,
  request: NextRequest,
): boolean {
  if (NATIVE_SCHEMES.has(scheme)) return true;
  if (scheme === "cmux-dev") return isLocalRequest(request);
  if (!/^cmux-dev-[a-z0-9-]+$/.test(scheme)) return false;
  return isLocalRequest(request) && localAllowedNativeSchemes().has(scheme);
}

export function isLocalRequest(request: NextRequest): boolean {
  const hostHeader = request.headers.get("host");
  const host = (hostHeader?.split(":")[0] ?? request.nextUrl.hostname).toLowerCase();
  return host === "localhost" || host === "127.0.0.1" || host === "::1";
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
