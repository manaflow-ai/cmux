import { NextRequest, type NextResponse } from "next/server";
import { directDevBackendOrigin } from "./direct-dev-backend-origin";

/**
 * Return the origin that application code should use for absolute URLs.
 *
 * Next.js development servers bind to 0.0.0.0. Tailscale Serve forwards the
 * real HTTPS host, but Next's default request URL can still use the bind
 * address. The daemon writes a validated direct URL into the container. Use
 * it only for that transport, and keep request.nextUrl.origin everywhere else.
 */
export function requestOrigin(
  request: NextRequest,
  environment: Record<string, string | undefined> = process.env,
): string {
  return directDevBackendOrigin(environment)?.origin ?? request.nextUrl.origin;
}

/**
 * Give middleware the same public URL that direct server routes use. This is
 * needed because next-intl creates redirects and rewrites from the request
 * URL it receives, before application route code runs.
 */
export function requestWithOrigin(
  request: NextRequest,
  environment: Record<string, string | undefined> = process.env,
): NextRequest {
  const origin = requestOrigin(request, environment);
  if (origin === request.nextUrl.origin) return request;
  const url = new URL(
    `${request.nextUrl.pathname}${request.nextUrl.search}`,
    origin,
  );
  return new NextRequest(url, {
    headers: request.headers,
    method: request.method,
  });
}

/** Public URLs belong in redirects; local rewrites must stay inside Next.
 * Rewriting through Tailscale Serve runs middleware again and loops when
 * next-intl removes the default locale prefix from its own rewrite. */
export function responseWithInternalRewrite(
  response: NextResponse,
  incomingRequest: NextRequest,
  environment: Record<string, string | undefined> = process.env,
): NextResponse {
  const publicOrigin = directDevBackendOrigin(environment)?.origin;
  const rewrite = response.headers.get("x-middleware-rewrite");
  if (!publicOrigin || !rewrite) return response;
  const target = new URL(rewrite);
  if (target.origin !== publicOrigin) return response;
  target.protocol = incomingRequest.nextUrl.protocol;
  target.host = incomingRequest.nextUrl.host;
  response.headers.set("x-middleware-rewrite", target.toString());
  return response;
}
