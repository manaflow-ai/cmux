import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { stackServerApp } from "../../lib/stack";
import { env } from "../../env";
import { OpenNativeClient } from "./OpenNativeClient";

export const dynamic = "force-dynamic";

const NATIVE_SCHEME = "cmux://";

function findStackCookie(
  cookieStore: { getAll: () => { name: string; value: string }[] },
  baseName: string
): string | undefined {
  const all = cookieStore.getAll();
  for (const prefix of ["__Host-", "__Secure-", ""]) {
    const withBranch = all.find(
      (c) => c.name.startsWith(`${prefix}${baseName}--`) && c.value
    );
    if (withBranch) return withBranch.value;
    const exact = all.find(
      (c) => c.name === `${prefix}${baseName}` && c.value
    );
    if (exact) return exact.value;
  }
  return undefined;
}

function decodeAccessCookie(value: string | undefined): { refreshToken?: string; accessToken?: string } {
  if (!value) return {};
  const decoded = value.includes("%") ? decodeURIComponent(value) : value;
  if (!decoded.startsWith("[")) return { accessToken: decoded };
  try {
    const arr = JSON.parse(decoded) as unknown[];
    if (Array.isArray(arr) && arr.length >= 2) {
      return { refreshToken: arr[0] as string, accessToken: arr[1] as string };
    }
  } catch {}
  return {};
}

function decodeRefreshCookie(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const decoded = value.includes("%") ? decodeURIComponent(value) : value;
  if (!decoded.startsWith("{")) return decoded;
  try {
    const obj = JSON.parse(decoded) as Record<string, unknown>;
    if (typeof obj.refresh_token === "string") return obj.refresh_token;
  } catch {}
  return undefined;
}

function buildNativeHref(
  baseHref: string | null,
  refreshToken: string | undefined,
  accessCookie: string | undefined
): string | null {
  if (!refreshToken || !accessCookie) return baseHref;
  const href = baseHref ?? `${NATIVE_SCHEME}auth-callback`;
  try {
    const url = new URL(href);
    url.searchParams.set("stack_refresh", refreshToken);
    url.searchParams.set("stack_access", accessCookie);
    return url.toString();
  } catch {
    return `${NATIVE_SCHEME}auth-callback?stack_refresh=${encodeURIComponent(refreshToken)}&stack_access=${encodeURIComponent(accessCookie)}`;
  }
}

type Props = {
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
};

export default async function AfterSignInPage({ searchParams: searchParamsPromise }: Props) {
  const stackCookies = await cookies();
  const refreshBaseName = `stack-refresh-${env.NEXT_PUBLIC_STACK_PROJECT_ID}`;
  const rawRefreshCookie = findStackCookie(stackCookies, refreshBaseName);
  const rawAccessCookie = findStackCookie(stackCookies, "stack-access");
  const parsedAccess = decodeAccessCookie(rawAccessCookie);
  const parsedRefresh = decodeRefreshCookie(rawRefreshCookie);

  let refreshToken = parsedAccess.refreshToken ?? parsedRefresh;
  let accessToken = parsedAccess.accessToken;
  let accessCookie = rawAccessCookie ? (rawAccessCookie.includes("%") ? decodeURIComponent(rawAccessCookie) : rawAccessCookie) : undefined;

  // Create a fresh session to get valid tokens for the native app
  try {
    const user = await stackServerApp.getUser({ or: "return-null" });
    if (user) {
      const session = await user.createSession({ expiresInMillis: 30 * 24 * 60 * 60 * 1000 });
      const tokens = await session.getTokens();
      if (tokens.refreshToken) refreshToken = tokens.refreshToken;
      if (tokens.accessToken) accessToken = tokens.accessToken;
    }
  } catch (error) {
    console.error("[After Sign In] Failed to create fresh session", error);
  }

  if (refreshToken && accessToken) {
    accessCookie = JSON.stringify([refreshToken, accessToken]);
  }

  const searchParams = await searchParamsPromise;
  const nativeReturnTo = typeof searchParams?.native_app_return_to === "string"
    ? searchParams.native_app_return_to
    : null;

  // Native app deep link. Only emit the handoff when both tokens are
  // available; otherwise the OpenNativeClient would launch cmux with an empty
  // auth payload, which would produce a spurious "not signed in" flash.
  if (
    refreshToken &&
    accessCookie &&
    (nativeReturnTo?.startsWith(NATIVE_SCHEME) || nativeReturnTo?.startsWith("cmux-dev://"))
  ) {
    const href = buildNativeHref(nativeReturnTo, refreshToken, accessCookie);
    if (href) return <OpenNativeClient href={href} />;
  }

  // Web redirect (relative paths only). Reject protocol-relative paths like
  // "//evil.com" that Next.js would treat as external redirects.
  const afterAuth = typeof searchParams?.after_auth_return_to === "string"
    ? searchParams.after_auth_return_to
    : null;
  if (afterAuth && afterAuth.startsWith("/") && !afterAuth.startsWith("//")) {
    redirect(afterAuth);
  }

  // Fallback: try native app only when we actually have tokens to hand off.
  if (refreshToken && accessCookie) {
    const fallback = buildNativeHref(null, refreshToken, accessCookie);
    if (fallback) return <OpenNativeClient href={fallback} />;
  }

  redirect("/");
}
