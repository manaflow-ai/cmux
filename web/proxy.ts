import { type NextRequest, NextResponse } from "next/server";
import createMiddleware from "next-intl/middleware";
import { routing } from "./i18n/routing";
import { isAgentPageVariantPath } from "./app/lib/agent-page-paths";
import {
  featureWorkflowContentLocales,
  featureWorkflowDocRequestForPathname,
} from "./i18n/locale-availability";
import { buildAlternateLinkHeader } from "./i18n/seo";
import { resolveSignedInForwardTarget } from "./app/lib/signed-in-forward";
import {
  verifyStackSessionUser,
  type StackSessionVerifyFetch,
} from "./app/lib/stack-session-edge";

const intlMiddleware = createMiddleware(routing);

export function buildMiddleware(verifyFetch: StackSessionVerifyFetch = fetch) {
  return async function middleware(request: NextRequest) {
    const host = request.headers.get("host") ?? "";

    // 301 redirect cmux.dev (and www.cmux.dev) to cmux.com, preserving path and query
    if (host === "cmux.dev" || host === "www.cmux.dev") {
      const url = new URL(request.url);
      url.host = "cmux.com";
      url.protocol = "https:";
      return NextResponse.redirect(url.toString(), 301);
    }

    const { pathname } = request.nextUrl;

    if (pathname.startsWith("/handler/")) {
      if (pathname === "/handler/sign-in" || pathname === "/handler/sign-up") {
        const signedInForwardTarget = await resolveSignedInForwardTarget({
          pathSegments: pathname.slice("/handler/".length).split("/"),
          searchParams: searchParamsRecord(request.nextUrl.searchParams),
          requestHost: request.headers.get("host"),
          getUser: () => verifyStackSessionUser(request, verifyFetch),
        });
        if (signedInForwardTarget) {
          return NextResponse.redirect(new URL(signedInForwardTarget, request.nextUrl.origin), 307);
        }
      }
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

    // Post-checkout pages live outside the [locale] tree, like /app-pricing.
    // Without this bypass next-intl rewrites them into /<locale>/billing/...,
    // which has no route and 404s via the pass-through root layout.
    if (pathname === "/billing" || pathname.startsWith("/billing/")) {
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
  };
}

export default buildMiddleware();

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

function searchParamsRecord(searchParams: URLSearchParams): Record<string, string | string[]> {
  const result: Record<string, string | string[]> = {};
  for (const key of new Set(searchParams.keys())) {
    const values = searchParams.getAll(key);
    result[key] = values.length === 1 ? values[0] ?? "" : values;
  }
  return result;
}

export const config = {
  matcher: [
    "/((?!api|_next|_vercel|agent-page-variant|handler).*)",
    "/handler/sign-in",
    "/handler/sign-up",
  ],
};
