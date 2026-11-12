import type { NextRequest } from "next/server";

export const DEFAULT_NATIVE_CALLBACK_SCHEME = "cmux";
export const NATIVE_CALLBACK_HOST = "auth-callback";

const NATIVE_SCHEMES = new Set([
  DEFAULT_NATIVE_CALLBACK_SCHEME,
  "cmux-nightly",
  "cmux-rc",
  // nightly-next's cmux NEXT, installed beside cmux NIGHTLY.
  "cmux-next",
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

/**
 * A DEV build's callback scheme: `cmux-dev`, or `cmux-dev-<tag>` with the tag
 * as CloudConfiguration.sanitizedSchemeTag writes it (lowercase letters and
 * digits joined by single hyphens, any length: build tooling does not cap tags).
 */
const DEV_BUILD_SCHEME = /^cmux-dev(?:-[a-z0-9]+)*$/;

/**
 * Whether a sign-in may hand its session back to `scheme`: a shipped
 * channel, or any cmux DEV build. A DEV build pointed at production
 * (`CMUX_AUTH_ENVIRONMENT=production`) signs in through the same hosted page
 * as the shipped app, and the app that started the sign-in checks the
 * callback's `cmux_auth_state` against its own attempt, so no per-build
 * allowlist on the server is needed. Every other scheme is refused.
 */
export function isNativeSignInScheme(scheme: string): boolean {
  if (NATIVE_SCHEMES.has(scheme)) return true;
  return DEV_BUILD_SCHEME.test(scheme);
}

/**
 * Whether after-sign-in may hand the fresh session to `href`: exactly
 * `<scheme>://auth-callback` for a scheme `isNativeSignInScheme` accepts, on
 * any host. Billing keeps its own stricter check (`isAllowedNativeScheme`).
 */
export function isAllowedNativeReturnTo(href: string): boolean {
  try {
    const url = new URL(href);
    if (url.hostname !== NATIVE_CALLBACK_HOST) return false;
    if (url.pathname !== "" && url.pathname !== "/") return false;
    return isNativeSignInScheme(url.protocol.replace(":", ""));
  } catch {
    return false;
  }
}

export function isAllowedNativeScheme(
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
