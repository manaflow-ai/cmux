import { NextRequest, NextResponse } from "next/server";
import { env } from "../../env";
import { stackServerApp } from "../../lib/stack";

export const dynamic = "force-dynamic";

type SignOutAndSignInDependencies = {
  projectId: string | undefined;
  signOut: ((options: { redirectUrl: string }) => Promise<void>) | null;
};

const STACK_ACCESS_COOKIE = "stack-access";
const LEGACY_STACK_REFRESH_COOKIE = "stack-refresh";

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

  return `${target.pathname}${target.search}${target.hash}`;
}

function canStartSignOut(request: NextRequest): boolean {
  const fetchSite = request.headers.get("sec-fetch-site");
  return fetchSite === null || fetchSite === "none" || fetchSite === "same-origin" || fetchSite === "same-site";
}

function isStackAuthCookie(name: string, projectId: string): boolean {
  const refreshName = `stack-refresh-${projectId}`;
  return (
    name === STACK_ACCESS_COOKIE ||
    name === `__Host-${STACK_ACCESS_COOKIE}` ||
    name === `__Secure-${STACK_ACCESS_COOKIE}` ||
    name === LEGACY_STACK_REFRESH_COOKIE ||
    name === `__Host-${LEGACY_STACK_REFRESH_COOKIE}` ||
    name === `__Secure-${LEGACY_STACK_REFRESH_COOKIE}` ||
    name === refreshName ||
    name === `__Host-${refreshName}` ||
    name === `__Secure-${refreshName}` ||
    name.startsWith(`${refreshName}--`) ||
    name.startsWith(`__Host-${refreshName}--`) ||
    name.startsWith(`__Secure-${refreshName}--`)
  );
}

function clearStackAuthCookies(response: NextResponse, request: NextRequest, projectId: string) {
  const secure = request.nextUrl.protocol === "https:";
  for (const cookie of request.cookies.getAll()) {
    if (!isStackAuthCookie(cookie.name, projectId)) continue;
    response.cookies.set(cookie.name, "", {
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
