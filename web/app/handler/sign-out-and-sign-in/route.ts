import { NextRequest, NextResponse } from "next/server";
import { env } from "../../env";
import { requestIsExternallySecure } from "../../lib/request-scheme";
import { stackServerApp } from "../../lib/stack";

export const dynamic = "force-dynamic";

type SignOutAndSignInDependencies = {
  projectId: string | undefined;
  signOut: ((options: { redirectUrl: string }) => Promise<void>) | null;
};

const STACK_ACCESS_COOKIE_NAMES = ["hexclave-access", "stack-access"] as const;
const LEGACY_STACK_REFRESH_COOKIE = "stack-refresh";
const STACK_CUSTOM_REFRESH_COOKIE_MARKER = "--custom-";
const CROCKFORD_BASE32_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

function sameOriginURL(value: string | null, request: NextRequest): URL | null {
  if (!value) return null;
  try {
    const url = new URL(value, request.nextUrl.origin);
    return url.origin === request.nextUrl.origin ? url : null;
  } catch {
    return null;
  }
}

function validatedNativeSignInTarget(request: NextRequest): string | null {
  const target = sameOriginURL(request.nextUrl.searchParams.get("after_auth_return_to"), request);
  if (!target || target.pathname !== "/handler/native-sign-in") return null;

  const afterAuth = sameOriginURL(target.searchParams.get("after_auth_return_to"), request);
  if (!afterAuth || afterAuth.pathname !== "/handler/after-sign-in") return null;
  if (!afterAuth.searchParams.has("native_app_return_to")) return null;
  if (afterAuth.searchParams.has("after_auth_return_to")) return null;

  return `${target.pathname}${target.search}${target.hash}`;
}

function canStartSignOut(request: NextRequest): boolean {
  const fetchSite = request.headers.get("sec-fetch-site");
  return fetchSite === "none" || fetchSite === "same-origin";
}

function isStackAuthCookie(name: string, projectId: string): boolean {
  const refreshNames = [
    `hexclave-refresh-${projectId}`,
    `stack-refresh-${projectId}`,
    LEGACY_STACK_REFRESH_COOKIE,
  ];
  return (
    STACK_ACCESS_COOKIE_NAMES.some((cookieName) => matchesStackCookieName(name, cookieName)) ||
    refreshNames.some((cookieName) => matchesStackCookieName(name, cookieName))
  );
}

function matchesStackCookieName(name: string, cookieName: string): boolean {
  for (const prefix of ["__Host-", "__Secure-", ""]) {
    if (name === `${prefix}${cookieName}` || name.startsWith(`${prefix}${cookieName}--`)) {
      return true;
    }
  }
  return false;
}

function decodeStackBase32Text(value: string): string | null {
  let bits = 0;
  let buffer = 0;
  const bytes: number[] = [];

  for (const character of value) {
    const index = CROCKFORD_BASE32_ALPHABET.indexOf(character.toUpperCase());
    if (index === -1) return null;
    buffer = (buffer << 5) | index;
    bits += 5;
    if (bits >= 8) {
      bytes.push((buffer >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }

  return new TextDecoder().decode(new Uint8Array(bytes));
}

function stackCustomRefreshCookieDomain(name: string, projectId: string): string | null {
  const cookieName = unprefixedCookieName(name);
  for (const refreshName of [`hexclave-refresh-${projectId}`, `stack-refresh-${projectId}`]) {
    const prefix = `${refreshName}${STACK_CUSTOM_REFRESH_COOKIE_MARKER}`;
    if (cookieName.startsWith(prefix)) return decodeStackBase32Text(cookieName.slice(prefix.length));
  }
  return null;
}

function unprefixedCookieName(name: string): string {
  if (name.startsWith("__Host-")) return name.slice("__Host-".length);
  if (name.startsWith("__Secure-")) return name.slice("__Secure-".length);
  return name;
}

function clearStackAuthCookies(response: NextResponse, request: NextRequest, projectId: string) {
  const secure = requestIsExternallySecure(request);
  for (const cookie of request.cookies.getAll()) {
    if (!isStackAuthCookie(cookie.name, projectId)) continue;
    const domain = stackCustomRefreshCookieDomain(cookie.name, projectId);
    response.cookies.set(cookie.name, "", {
      ...(domain ? { domain } : {}),
      httpOnly: true,
      maxAge: 0,
      path: "/",
      sameSite: "lax",
      secure: cookie.name.startsWith("__") || secure,
    });
  }
}

function isNextRedirectError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "digest" in error &&
    typeof error.digest === "string" &&
    error.digest.startsWith("NEXT_REDIRECT;")
  );
}

export function makeSignOutAndSignInHandler(dependencies: SignOutAndSignInDependencies) {
  return async function GET(request: NextRequest) {
    const target = validatedNativeSignInTarget(request);
    if (!target || !canStartSignOut(request)) return NextResponse.redirect(new URL("/", request.url));

    const response = NextResponse.redirect(new URL(target, request.url));
    if (dependencies.projectId) clearStackAuthCookies(response, request, dependencies.projectId);

    const redirectUrl = new URL(target, request.nextUrl.origin).toString();
    try {
      await dependencies.signOut?.({ redirectUrl });
    } catch (error) {
      if (!isNextRedirectError(error)) {
        console.warn("[Sign Out and Sign In] Continuing after Stack sign-out did not complete normally", error);
      }
    }
    return response;
  };
}

const configuredStackServerApp = stackServerApp;

export const GET = makeSignOutAndSignInHandler({
  projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
  signOut: configuredStackServerApp ? (options) => configuredStackServerApp.signOut(options) : null,
});
