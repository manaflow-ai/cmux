import { type NextRequest, NextResponse } from "next/server";
import createMiddleware from "next-intl/middleware";
import { routing } from "./i18n/routing";

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

  // Legal pages are English-only. Redirect /<locale>/legal-page to /legal-page,
  // and skip next-intl for /legal-page so locale detection can't redirect back.
  const legalPages = new Set(["/privacy-policy", "/terms-of-service", "/eula"]);
  const { pathname } = request.nextUrl;
  if (legalPages.has(pathname)) {
    const url = request.nextUrl.clone();
    url.pathname = `/en${pathname}`;
    return NextResponse.rewrite(url);
  }
  const secondSlash = pathname.indexOf("/", 1);
  if (secondSlash !== -1) {
    const rest = pathname.slice(secondSlash);
    if (legalPages.has(rest)) {
      const url = request.nextUrl.clone();
      url.pathname = rest;
      return NextResponse.redirect(url, 301);
    }
  }

  return intlMiddleware(request);
}

export const config = {
  matcher: ["/((?!api|_next|_vercel|.*\\..*).*)"],
};
