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

  return intlMiddleware(request);
}

export const config = {
  matcher: ["/((?!api|_next|_vercel|.*\\..*).*)"],
};
