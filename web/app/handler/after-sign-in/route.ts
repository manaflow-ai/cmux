import { cookies } from "next/headers";
import { NextRequest, NextResponse } from "next/server";
import { stackServerApp } from "../../lib/stack";
import { env } from "../../env";
import type { Locale } from "../../../i18n/routing";
import { locales, routing } from "../../../i18n/routing";

export const dynamic = "force-dynamic";

const NATIVE_SCHEME = "cmux://";
const NATIVE_SCHEMES = new Set(["cmux", "cmux-nightly"]);
const NATIVE_HANDOFF_COOKIE = "cmux-native-auth-handoff";
const NATIVE_HANDOFF_PARAM = "cmux_auth_handoff";

type AfterSignInMessages = {
  title: string;
  body: string;
  button: string;
};

type LocalizedAfterSignInMessages = {
  locale: Locale;
  messages: AfterSignInMessages;
};

function isLocalRequest(request: NextRequest): boolean {
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

function isAllowedNativeReturnTo(href: string, request: NextRequest): boolean {
  try {
    const url = new URL(href);
    if (url.hostname !== "auth-callback") return false;
    if (url.pathname !== "" && url.pathname !== "/") return false;
    const scheme = url.protocol.replace(":", "");
    if (NATIVE_SCHEMES.has(scheme)) return true;
    if (scheme === "cmux-dev") return isLocalRequest(request);
    return isLocalRequest(request) && localAllowedNativeSchemes().has(scheme);
  } catch {
    return false;
  }
}

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

function hasAuthState(href: string): boolean {
  try {
    return new URL(href).searchParams.has("cmux_auth_state");
  } catch {
    return false;
  }
}

function verifiedAutoOpen(
  request: NextRequest,
  cookieStore: { get: (name: string) => { value: string } | undefined },
  nativeReturnTo: string
): boolean {
  if (!hasAuthState(nativeReturnTo)) return false;
  const handoffNonce = request.nextUrl.searchParams.get(NATIVE_HANDOFF_PARAM);
  if (!handoffNonce) return false;
  return cookieStore.get(NATIVE_HANDOFF_COOKIE)?.value === handoffNonce;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function preferredLocale(request: NextRequest): Locale {
  const accepted = request.headers.get("accept-language") ?? "";
  const requested = accepted
    .split(",")
    .map((part) => part.split(";")[0]?.trim())
    .filter(Boolean);
  for (const language of requested) {
    const exact = locales.find((locale) => locale.toLowerCase() === language.toLowerCase());
    if (exact) return exact;
    const base = language.split("-")[0]?.toLowerCase();
    const baseMatch = locales.find((locale) => locale.toLowerCase().split("-")[0] === base);
    if (baseMatch) return baseMatch;
  }
  return routing.defaultLocale;
}

async function afterSignInMessages(request: NextRequest): Promise<LocalizedAfterSignInMessages> {
  const locale = preferredLocale(request);
  const messages = (await import(`../../../messages/${locale}.json`)).default as {
    afterSignIn?: AfterSignInMessages;
  };
  return {
    locale,
    messages: messages.afterSignIn ?? {
      title: "Signed in to cmux",
      body: "If cmux did not open automatically, use the button below.",
      button: "Return to cmux",
    },
  };
}

function nativeReturnResponse(
  href: string,
  localized: LocalizedAfterSignInMessages,
  autoOpen: boolean
): NextResponse {
  const { locale, messages } = localized;
  const escapedHref = escapeHtml(href);
  const scriptHref = JSON.stringify(href).replaceAll("<", "\\u003c");
  const escapedTitle = escapeHtml(messages.title);
  const escapedBody = escapeHtml(messages.body);
  const escapedButton = escapeHtml(messages.button);
  const autoOpenHead = autoOpen
    ? `  <meta http-equiv="refresh" content="0;url=${escapedHref}">\n`
    : "";
  const autoOpenScript = autoOpen
    ? `  <script>\n    window.location.replace(${scriptHref});\n  </script>\n`
    : "";
  const response = new NextResponse(
    `<!doctype html>
<html lang="${escapeHtml(locale)}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
${autoOpenHead}  <title>${escapedTitle}</title>
  <style>
    body {
      align-items: center;
      background: #fff;
      color: #111;
      display: flex;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, sans-serif;
      justify-content: center;
      margin: 0;
      min-height: 100vh;
      padding: 24px;
    }
    main {
      max-width: 440px;
      text-align: center;
    }
    h1 {
      font-size: 24px;
      font-weight: 600;
      margin: 0 0 12px;
    }
    p {
      color: #555;
      line-height: 1.5;
      margin: 0 0 24px;
    }
    a {
      background: #111;
      border-radius: 8px;
      color: #fff;
      display: inline-block;
      font-size: 14px;
      font-weight: 500;
      padding: 10px 18px;
      text-decoration: none;
    }
  </style>
</head>
<body>
  <main>
    <h1>${escapedTitle}</h1>
    <p>${escapedBody}</p>
    <a href="${escapedHref}">${escapedButton}</a>
  </main>
${autoOpenScript}
</body>
</html>`,
    {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
      },
    }
  );
  if (autoOpen) {
    response.cookies.set(NATIVE_HANDOFF_COOKIE, "", {
      httpOnly: true,
      maxAge: 0,
      path: "/handler/after-sign-in",
      sameSite: "lax",
      secure: requestIsSecure(),
    });
  }
  return response;
}

function requestIsSecure(): boolean {
  return process.env.NODE_ENV === "production";
}

export async function GET(request: NextRequest) {
  const projectId = env.NEXT_PUBLIC_STACK_PROJECT_ID;
  if (!stackServerApp || !projectId) return NextResponse.redirect(new URL("/", request.url));
  const localizedMessages = await afterSignInMessages(request);

  const stackCookies = await cookies();
  const refreshBaseName = `stack-refresh-${projectId}`;
  const rawRefreshCookie = findStackCookie(stackCookies, refreshBaseName);
  const rawAccessCookie = findStackCookie(stackCookies, "stack-access");
  const parsedAccess = decodeAccessCookie(rawAccessCookie);
  const parsedRefresh = decodeRefreshCookie(rawRefreshCookie);

  let refreshToken = parsedAccess.refreshToken ?? parsedRefresh;
  let accessToken = parsedAccess.accessToken;
  let accessCookie = rawAccessCookie ? (rawAccessCookie.includes("%") ? decodeURIComponent(rawAccessCookie) : rawAccessCookie) : undefined;

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

  const nativeReturnTo = request.nextUrl.searchParams.get("native_app_return_to");
  if (
    refreshToken &&
    accessCookie &&
    nativeReturnTo !== null
  ) {
    if (isAllowedNativeReturnTo(nativeReturnTo, request)) {
      const href = buildNativeHref(nativeReturnTo, refreshToken, accessCookie);
      const autoOpen = verifiedAutoOpen(request, stackCookies, nativeReturnTo);
      if (href) return nativeReturnResponse(href, localizedMessages, autoOpen);
    }
    return NextResponse.redirect(new URL("/", request.url));
  }

  const afterAuth = request.nextUrl.searchParams.get("after_auth_return_to");
  if (afterAuth && afterAuth.startsWith("/") && !afterAuth.startsWith("//")) {
    return NextResponse.redirect(new URL(afterAuth, request.url));
  }

  if (refreshToken && accessCookie) {
    const fallback = buildNativeHref(null, refreshToken, accessCookie);
    if (fallback) return nativeReturnResponse(fallback, localizedMessages, false);
  }

  return NextResponse.redirect(new URL("/", request.url));
}
