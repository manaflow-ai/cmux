import { type NextRequest, NextResponse } from "next/server";
import createMiddleware from "next-intl/middleware";
import { preferredLocaleFromAcceptLanguage } from "./i18n/accept-language";
import { routing } from "./i18n/routing";
import { isAgentPageVariantPath } from "./app/lib/agent-page-paths";
import {
  fallbackContentRequestForPathname,
  featureWorkflowContentLocales,
  featureWorkflowDocRequestForPathname,
  hasFallbackContent,
  remoteTmuxDocsLocales,
} from "./i18n/locale-availability";
import { buildAlternateLinkHeader } from "./i18n/seo";

const intlMiddleware = createMiddleware(routing);

export default function middleware(request: NextRequest) {
  const host = request.headers.get("host") ?? "";

  // 301 redirect cmux.dev (and www.cmux.dev) to cmux.com, preserving path and query
  if (host === "cmux.dev" || host === "www.cmux.dev") {
    const url = new URL(request.url);
    url.host = "cmux.com";
    url.protocol = "https:";
    return NextResponse.redirect(url.toString(), 301);
  }

  const { pathname } = request.nextUrl;

  // The public site only routes docs traffic to the release/nightly origins.
  // Locale handling belongs to those origins; rewriting it here first causes
  // the origin to normalize the path back through the router in a loop.
  const docsChannel = process.env.CMUX_DOCS_CHANNEL;
  const isDocsOrigin = docsChannel === "release" || docsChannel === "nightly";
  const isDocsPath = /^\/(?:[a-z]{2}(?:-[A-Z]{2})?\/)?docs(?:\/|$)/u.test(
    pathname,
  );
  if (!isDocsOrigin && isDocsPath) {
    return NextResponse.next();
  }

  // Temporary redirect: /changelog → /docs/changelog, preserving any locale prefix.
  const changelogMatch = pathname.match(/^(\/[a-z]{2}(?:-[A-Z]{2})?)?\/changelog\/?$/);
  if (changelogMatch) {
    const url = request.nextUrl.clone();
    url.pathname = `${changelogMatch[1] ?? ""}/docs/changelog`;
    return NextResponse.redirect(url, 307);
  }

  if (isAgentPageVariantPath(pathname)) {
    const url = request.nextUrl.clone();
    url.pathname = "/agent-page-variant";
    url.searchParams.set("path", pathname);
    const requestHeaders = new Headers(request.headers);
    requestHeaders.set("x-cmux-agent-page-path", pathname);
    return NextResponse.rewrite(url, {
      request: { headers: requestHeaders },
    });
  }

  if (pathname === "/app-pricing" || pathname === "/app-pricing/") {
    return NextResponse.next();
  }

  // This is a localized image endpoint, but the default-locale URL is
  // intentionally unprefixed to match the canonical social metadata URL.
  if (pathname === "/opengraph-image" || pathname === "/opengraph-image/") {
    return NextResponse.next();
  }

  if (pathname === "/app-pro-welcome" || pathname === "/app-pro-welcome/") {
    return NextResponse.next();
  }

  // Post-checkout pages live outside the [locale] tree, like /app-pricing.
  // Without this bypass next-intl rewrites them into /<locale>/billing/...,
  // which has no route and 404s via the pass-through root layout.
  if (pathname === "/billing" || pathname.startsWith("/billing/")) {
    return NextResponse.next();
  }

  // Stripe returns cmux Cloud users to one fixed, status-qualified URL.
  // Keep it outside the localized route tree so every Checkout and portal
  // session can share the same production URL.
  if (pathname === "/cloud/billing" || pathname === "/cloud/billing/") {
    return NextResponse.next();
  }

  if (pathname.includes(".")) {
    return NextResponse.next();
  }

  const featureWorkflowDocRequest =
    featureWorkflowDocRequestForPathname(pathname);
  if (featureWorkflowDocRequest && !featureWorkflowDocRequest.locale) {
    const url = request.nextUrl.clone();
    url.pathname = `/en${featureWorkflowDocRequest.path}`;
    const response = NextResponse.rewrite(url);
    setFeatureWorkflowDocLinkHeader(
      response,
      request,
      featureWorkflowDocRequest.path,
    );
    return response;
  }

  const fallbackContentRequest = fallbackContentRequestForPathname(pathname);
  if (fallbackContentRequest && !fallbackContentRequest.locale) {
    const preferredLocale = preferredFallbackContentLocale(
      request,
      fallbackContentRequest.locales,
    );
    const url = request.nextUrl.clone();
    url.pathname = `/${preferredLocale}${fallbackContentRequest.path}`;
    const response =
      preferredLocale === "en"
        ? NextResponse.rewrite(url)
        : NextResponse.redirect(url, 307);
    setFallbackContentLinkHeader(
      response,
      request,
      fallbackContentRequest.path,
      fallbackContentRequest.locales,
    );
    return response;
  }
  if (
    fallbackContentRequest?.locale &&
    !hasFallbackContent(
      fallbackContentRequest.locale,
      fallbackContentRequest.locales,
    )
  ) {
    const url = request.nextUrl.clone();
    url.pathname = fallbackContentRequest.path;
    return NextResponse.redirect(url, 301);
  }

  // The remaining legal pages are English-only. Redirect
  // /<locale>/legal-page to /legal-page, and skip next-intl for /legal-page so
  // locale detection can't redirect back. The privacy policy has complete
  // localized content and follows the normal next-intl path.
  const englishOnlyPages = new Set([
    "/terms-of-service",
    "/eula",
  ]);
  if (englishOnlyPages.has(pathname)) {
    const url = request.nextUrl.clone();
    url.pathname = `/en${pathname}`;
    return NextResponse.rewrite(url);
  }
  const secondSlash = pathname.indexOf("/", 1);
  if (secondSlash !== -1) {
    const rest = pathname.slice(secondSlash);
    if (englishOnlyPages.has(rest)) {
      const url = request.nextUrl.clone();
      url.pathname = rest;
      return NextResponse.redirect(url, 301);
    }
  }

  // Base docs are English-only. Keep the canonical URL unprefixed and bypass
  // locale detection so browser language preferences cannot select a 404.
  const baseDocsMatch = pathname.match(
    /^\/([a-z]{2}(?:-[A-Z]{2})?)\/docs\/base\/?$/,
  );
  if (baseDocsMatch && baseDocsMatch[1] !== "en") {
    const url = request.nextUrl.clone();
    url.pathname = "/docs/base";
    return NextResponse.redirect(url, 301);
  }
  if (pathname === "/docs/base" || pathname === "/docs/base/") {
    const url = request.nextUrl.clone();
    url.pathname = "/en/docs/base";
    return NextResponse.rewrite(url);
  }

  const remoteTmuxMatch = pathname.match(
    /^\/([a-z]{2}(?:-[A-Z]{2})?)\/docs\/remote-tmux\/?$/,
  );
  if (
    remoteTmuxMatch &&
    !remoteTmuxDocsLocales.includes(
      remoteTmuxMatch[1] as (typeof remoteTmuxDocsLocales)[number],
    )
  ) {
    const url = request.nextUrl.clone();
    url.pathname = "/docs/remote-tmux";
    return NextResponse.redirect(url, 301);
  }
  if (pathname === "/docs/remote-tmux" || pathname === "/docs/remote-tmux/") {
    const url = request.nextUrl.clone();
    url.pathname = "/en/docs/remote-tmux";
    return NextResponse.rewrite(url);
  }

  const response = intlMiddleware(request);
  if (featureWorkflowDocRequest) {
    setFeatureWorkflowDocLinkHeader(
      response,
      request,
      featureWorkflowDocRequest.path,
    );
  }
  if (fallbackContentRequest) {
    setFallbackContentLinkHeader(
      response,
      request,
      fallbackContentRequest.path,
      fallbackContentRequest.locales,
    );
  }

  return response;
}

function setFallbackContentLinkHeader(
  response: NextResponse,
  request: NextRequest,
  path: string,
  availableLocales: readonly (typeof routing.locales)[number][],
) {
  response.headers.set(
    "Link",
    buildAlternateLinkHeader(
      requestOrigin(request),
      path,
      availableLocales,
    ),
  );
}

function preferredFallbackContentLocale(
  request: NextRequest,
  availableLocales: readonly (typeof routing.locales)[number][],
): (typeof routing.locales)[number] {
  const cookieLocale = request.cookies.get("NEXT_LOCALE")?.value;
  if (cookieLocale && hasFallbackContent(cookieLocale, availableLocales)) {
    return cookieLocale as (typeof routing.locales)[number];
  }
  if (cookieLocale && routing.locales.some((locale) => locale === cookieLocale)) {
    return "en";
  }

  return preferredLocaleFromAcceptLanguage(
    request.headers.get("accept-language") ?? "",
    availableLocales,
    availableLocales[0] ?? routing.defaultLocale,
  );
}

function setFeatureWorkflowDocLinkHeader(
  response: NextResponse,
  request: NextRequest,
  path: string,
) {
  response.headers.set(
    "Link",
    buildAlternateLinkHeader(
      requestOrigin(request),
      path,
      featureWorkflowContentLocales,
    ),
  );
}

function requestOrigin(request: NextRequest) {
  return request.nextUrl.origin;
}

export const config = {
  matcher: ["/((?!api|_next|_vercel|agent-page-variant|handler).*)"],
};
