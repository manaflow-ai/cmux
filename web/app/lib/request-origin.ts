import { NextRequest } from "next/server";

const DIRECT_PORT_MIN = 3800;
const DIRECT_PORT_MAX = 4799;

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
  if (environment.CMUX_DEV_BACKEND_TRANSPORT !== "direct") {
    return request.nextUrl.origin;
  }

  const configured = environment.CMUX_WWW_ORIGIN?.trim();
  if (!configured) return request.nextUrl.origin;

  try {
    const url = new URL(configured);
    const host = url.hostname.toLowerCase();
    const port = url.port ? Number(url.port) : 443;
    if (
      url.protocol !== "https:" ||
      !host.endsWith(".ts.net") ||
      !Number.isInteger(port) ||
      port < DIRECT_PORT_MIN ||
      port > DIRECT_PORT_MAX ||
      url.username ||
      url.password ||
      (url.pathname !== "" && url.pathname !== "/") ||
      url.search ||
      url.hash
    ) {
      return request.nextUrl.origin;
    }
    return url.origin;
  } catch {
    return request.nextUrl.origin;
  }
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
