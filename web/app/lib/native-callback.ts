import type { NextRequest } from "next/server";

export const DEFAULT_NATIVE_CALLBACK_SCHEME = "cmux";
export const NATIVE_CALLBACK_HOST = "auth-callback";

const NATIVE_SCHEMES = new Set([DEFAULT_NATIVE_CALLBACK_SCHEME, "cmux-nightly"]);
const TAGGED_DEV_SCHEME_PATTERN = /^cmux-dev-[a-z0-9-]+$/;

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

/**
 * Whether `scheme` is one a cmux build registers for its auth callback: the
 * stable app, the nightly, an untagged Debug build (`cmux-dev`), or a tagged
 * Debug build (`cmux-dev-<tag>`, the tag as the app's callback-scheme
 * sanitizer writes it: lowercase letters, digits, and hyphens).
 */
export function isNativeCallbackScheme(scheme: string): boolean {
  if (NATIVE_SCHEMES.has(scheme) || scheme === "cmux-dev") return true;
  return TAGGED_DEV_SCHEME_PATTERN.test(scheme);
}

export function trustedNativeCallbackScheme(
  rawScheme: string | null | undefined,
): string | null {
  const scheme = rawScheme?.trim().toLowerCase() ?? "";
  return isNativeCallbackScheme(scheme) ? scheme : null;
}

/**
 * Whether the after-sign-in handler may hand the fresh session to `href`.
 *
 * Every cmux build's callback is honored on every host, the deployed one
 * included: a Debug build pointed at production (`reload.sh --prod-auth`)
 * signs in through the same hosted flow as the stable app, and the build that
 * started the sign-in verifies the callback's `cmux_auth_state` against its
 * own attempt, so the web never decides which build a session belongs to. It
 * only refuses targets no cmux build registers. Purchase returns keep their
 * separate relay signature (see `billing.ts`); it binds the checkout session,
 * not the scheme.
 */
export function isAllowedNativeReturnTo(href: string): boolean {
  try {
    const url = new URL(href);
    if (url.hostname !== NATIVE_CALLBACK_HOST) return false;
    if (url.pathname !== "" && url.pathname !== "/") return false;
    return isNativeCallbackScheme(url.protocol.replace(":", ""));
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
  if (!TAGGED_DEV_SCHEME_PATTERN.test(scheme)) return false;
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
      if (TAGGED_DEV_SCHEME_PATTERN.test(scheme)) schemes.add(scheme);
    }
  }
  return schemes;
}
