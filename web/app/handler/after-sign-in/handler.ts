import { NextRequest, NextResponse } from "next/server";
import type { Locale } from "../../../i18n/routing";
import { locales, routing } from "../../../i18n/routing";
import {
  NATIVE_HANDOFF_COOKIE,
  NATIVE_HANDOFF_PARAM,
  NATIVE_PLATFORM_PARAM,
  type AfterSignInMessages,
  type NativeReturnLink,
  buildMobileNativeErrorHref,
  buildNativeHref,
  fallbackNativeLinks,
  isAllowedNativeReturnTo,
  isMobileNativeReturnTo,
  nativePlatformFromValue,
  nativeReturnLabel,
} from "./native-return";

type LocalizedAfterSignInMessages = {
  locale: Locale;
  messages: AfterSignInMessages;
};

type CookieStore = {
  get: (name: string) => { value: string } | undefined;
  getAll: () => { name: string; value: string }[];
};

type StackAuthSessionLike = {
  getTokens: () => Promise<{
    refreshToken?: string | null;
    accessToken?: string | null;
  }>;
};

type StackAuthUserLike = {
  createSession: (options: { expiresInMillis: number }) => Promise<StackAuthSessionLike>;
};

type StackServerAppLike = {
  getUser: (options: { or: "return-null" }) => Promise<StackAuthUserLike | null>;
} | null;

type AfterSignInHandlerDependencies = {
  projectId: string | undefined;
  stackServerApp: StackServerAppLike;
  getCookieStore: () => Promise<CookieStore>;
};

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

function decodeCookieValue(value: string | undefined): string | undefined {
  if (!value) return undefined;
  if (!value.includes("%")) return value;
  try {
    return decodeURIComponent(value);
  } catch {
    return undefined;
  }
}

function decodeAccessCookie(value: string | undefined): { refreshToken?: string; accessToken?: string } {
  const decoded = decodeCookieValue(value);
  if (!decoded) return {};
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
  const decoded = decodeCookieValue(value);
  if (!decoded) return undefined;
  if (!decoded.startsWith("{")) return decoded;
  try {
    const obj = JSON.parse(decoded) as Record<string, unknown>;
    if (typeof obj.refresh_token === "string") return obj.refresh_token;
  } catch {}
  return undefined;
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
  if (!messages.afterSignIn) {
    throw new Error(`Missing afterSignIn messages for locale ${locale}`);
  }
  return {
    locale,
    messages: messages.afterSignIn,
  };
}

function nativeReturnResponse(
  href: string,
  localized: LocalizedAfterSignInMessages,
  autoOpen: boolean,
  label: string = localized.messages.button
): NextResponse {
  return nativeReturnLinksResponse([{ href, label }], localized, autoOpen, href);
}

function nativeReturnLinksResponse(
  links: NativeReturnLink[],
  localized: LocalizedAfterSignInMessages,
  autoOpen: boolean,
  autoOpenHref: string | null = links[0]?.href ?? null
): NextResponse {
  const { locale, messages } = localized;
  const scriptHref = autoOpenHref ? JSON.stringify(autoOpenHref).replaceAll("<", "\\u003c") : "null";
  const escapedTitle = escapeHtml(messages.title);
  const escapedBody = escapeHtml(messages.body);
  const escapedLinks = links
    .map((link) => `<a href="${escapeHtml(link.href)}">${escapeHtml(link.label)}</a>`)
    .join("\n    ");
  const autoOpenScript = autoOpen && autoOpenHref
    ? `  <script>\n    window.location.replace(${scriptHref});\n  </script>\n`
    : "";
  const response = new NextResponse(
    `<!doctype html>
<html lang="${escapeHtml(locale)}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapedTitle}</title>
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
      margin: 4px;
      padding: 10px 18px;
      text-decoration: none;
    }
  </style>
</head>
<body>
  <main>
    <h1>${escapedTitle}</h1>
    <p>${escapedBody}</p>
    ${escapedLinks}
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

export function makeAfterSignInHandler(dependencies: AfterSignInHandlerDependencies) {
  return async function GET(request: NextRequest) {
    const projectId = dependencies.projectId;
    const authApp = dependencies.stackServerApp;
    if (!authApp || !projectId) return NextResponse.redirect(new URL("/", request.url));
    const localizedMessages = await afterSignInMessages(request);

    const stackCookies = await dependencies.getCookieStore();
    const refreshBaseName = `stack-refresh-${projectId}`;
    const rawRefreshCookie = findStackCookie(stackCookies, refreshBaseName);
    const rawAccessCookie = findStackCookie(stackCookies, "stack-access");
    const parsedAccess = decodeAccessCookie(rawAccessCookie);
    const parsedRefresh = decodeRefreshCookie(rawRefreshCookie);

    let refreshToken = parsedAccess.refreshToken ?? parsedRefresh;
    let accessToken = parsedAccess.accessToken;
    let accessCookie = decodeCookieValue(rawAccessCookie);

    try {
      const user = await authApp.getUser({ or: "return-null" });
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
        const autoOpen = verifiedAutoOpen(request, stackCookies, nativeReturnTo);
        if (isMobileNativeReturnTo(nativeReturnTo)) {
          const href = buildMobileNativeErrorHref(nativeReturnTo);
          if (href) {
            return nativeReturnResponse(href, localizedMessages, autoOpen, nativeReturnLabel(nativeReturnTo, localizedMessages.messages));
          }
          return NextResponse.redirect(new URL("/", request.url));
        }
        const href = buildNativeHref(nativeReturnTo, refreshToken, accessCookie);
        if (href) {
          return nativeReturnResponse(href, localizedMessages, autoOpen, nativeReturnLabel(nativeReturnTo, localizedMessages.messages));
        }
      }
      return NextResponse.redirect(new URL("/", request.url));
    }

    const afterAuth = request.nextUrl.searchParams.get("after_auth_return_to");
    if (afterAuth && afterAuth.startsWith("/") && !afterAuth.startsWith("//")) {
      return NextResponse.redirect(new URL(afterAuth, request.url));
    }

    if (refreshToken && accessCookie) {
      const platform = nativePlatformFromValue(request.nextUrl.searchParams.get(NATIVE_PLATFORM_PARAM));
      const links = fallbackNativeLinks(refreshToken, accessCookie, localizedMessages.messages, platform);
      if (links.length > 0) return nativeReturnLinksResponse(links, localizedMessages, false);
    }

    return NextResponse.redirect(new URL("/", request.url));
  };
}
