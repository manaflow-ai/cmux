import type { NextRequest } from "next/server";

export const DEFAULT_NATIVE_CALLBACK_SCHEME = "cmux";
export const NATIVE_CALLBACK_HOST = "auth-callback";

const NATIVE_SCHEMES = new Set([
  DEFAULT_NATIVE_CALLBACK_SCHEME,
  "cmux-nightly",
  "cmux-rc",
  // nightly-next's cmux NEXT, installed beside cmux NIGHTLY.
  "cmux-next",
  // cmux NEXT Stable (scripts/ci/stable-next-identity.sh), installed beside cmux NEXT.
  "cmux-next-stable",
]);

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

export function isAllowedNativeScheme(
  scheme: string,
  request: NextRequest,
): boolean {
  // Signed NEXT DEV authenticates against staging, so never hand production
  // Stack tokens to that app when a callback is forged on cmux.com.
  if (scheme === "cmux-next-dev") return isStagingRequest(request);
  if (NATIVE_SCHEMES.has(scheme)) return true;
  const tagged = /^cmux-dev-[a-z0-9-]+$/.test(scheme);
  // Debug and tagged fleet builds sign in on staging by default (CloudConfiguration.resolve),
  // with staging's development Stack project, as signed NEXT DEV does above.
  if ((scheme === "cmux-dev" || tagged) && isStagingRequest(request)) return true;
  if (scheme === "cmux-dev") return isLocalRequest(request);
  if (!tagged) return false;
  return isLocalRequest(request) && localAllowedNativeSchemes().has(scheme);
}

/** The staging deployment of cmux.com; it signs in against the development sign-in project. */
export const STAGING_WEB_HOST = "cmux-staging.vercel.app";

/** The request's host name, lowercased, without a port. */
export function requestHostname(request: NextRequest): string {
  const hostHeader = request.headers.get("host");
  return (hostHeader?.split(":")[0] ?? request.nextUrl.hostname).toLowerCase();
}

export function isLocalRequest(request: NextRequest): boolean {
  const host = requestHostname(request);
  return host === "localhost" || host === "127.0.0.1" || host === "::1";
}

export function isStagingRequest(request: NextRequest): boolean {
  return requestHostname(request) === STAGING_WEB_HOST;
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
