import { type NextRequest, NextResponse } from "next/server";
import createMiddleware from "next-intl/middleware";
import { routing } from "./routing";

const routeLocale = createMiddleware(routing);

export function localeMiddleware(request: NextRequest): NextResponse {
  const response = routeLocale(request);
  // Next.js removes internal RSC headers before Proxy. Fetch Metadata survives
  // normalization and distinguishes browser fetches from document navigation.
  const destination = request.headers.get("sec-fetch-dest");
  const isBackgroundRequest = (destination !== null && destination !== "document")
    || request.headers.get("rsc") === "1"
    || request.headers.has("next-router-prefetch")
    || request.headers.get("purpose")?.includes("prefetch")
    || request.headers.get("sec-purpose")?.includes("prefetch");
  if (!isBackgroundRequest || !response.cookies.has("NEXT_LOCALE")) return response;

  // The selector owns explicit preference changes. A prefetch or RSC response
  // from the old page can arrive after that choice and must not overwrite it.
  // Keep next-intl's cookie-based routing, but persist inferred preferences only
  // for document navigation. Deleting via response.cookies would expire the
  // browser's cookie, so omit the write instead (including Next's internal copy).
  const headers = new Headers(response.headers);
  const cookies = headers.getSetCookie().filter((cookie) => !cookie.startsWith("NEXT_LOCALE="));
  headers.delete("set-cookie");
  headers.delete("x-middleware-set-cookie");
  for (const cookie of cookies) headers.append("set-cookie", cookie);
  if (cookies.length) headers.set("x-middleware-set-cookie", cookies.join(","));
  return new NextResponse(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
