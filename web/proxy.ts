import { type NextRequest, NextResponse } from "next/server";
import createMiddleware from "next-intl/middleware";
import { routing } from "./i18n/routing";
import { isAgentPageVariantPath } from "./app/lib/agent-page-paths";
import {
  featureWorkflowContentLocales,
  featureWorkflowDocRequestForPathname,
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

  // Legal pages are English-only. Redirect /<locale>/legal-page to /legal-page,
  // and skip next-intl for /legal-page so locale detection can't redirect back.
  const englishOnlyPages = new Set([
    "/privacy-policy",
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

  const response = intlMiddleware(request);
  if (featureWorkflowDocRequest) {
    setFeatureWorkflowDocLinkHeader(
      response,
      request,
      featureWorkflowDocRequest.path,
    );
  }

  return response;
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
