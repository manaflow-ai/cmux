import type { Span } from "@opentelemetry/api";
import { recordSpanError, withApiRouteSpan, type MaybeAttributes } from "../telemetry";
import { unauthorized, verifyRequest, type AuthedUser } from "./auth";

/** Bearer + refresh token pair the mac app stashes in keychain. */
export type StackBearer = { accessToken: string; refreshToken: string };

export function parseBearer(request: Request): StackBearer | null {
  const auth = request.headers.get("authorization");
  const refresh = request.headers.get("x-stack-refresh-token");
  if (!auth?.toLowerCase().startsWith("bearer ") || !refresh) return null;
  const accessToken = auth.slice("bearer ".length).trim();
  const refreshToken = refresh.trim();
  if (!accessToken || !refreshToken) return null;
  return { accessToken, refreshToken };
}

export type AuthedVmRouteContext = {
  user: AuthedUser;
  span: Span;
};

export async function withAuthedVmApiRoute(
  request: Request,
  route: string,
  attributes: MaybeAttributes,
  failureLog: string,
  handler: (context: AuthedVmRouteContext) => Promise<Response>,
): Promise<Response> {
  return withApiRouteSpan(
    request,
    route,
    { "cmux.subsystem": "vm-cloud", ...attributes },
    async (span) => {
      try {
        const bearer = parseBearer(request);
        const user = await verifyRequest(request);
        if (!user) return unauthorized();
        if (requiresBrowserMutationProtection(request.method, bearer) && !browserMutationOriginAllowed(request)) {
          return jsonResponse({ error: "forbidden" }, 403);
        }
        return await handler({ user, span });
      } catch (err) {
        recordSpanError(span, err);
        console.error(failureLog, err);
        return jsonResponse({ error: err instanceof Error ? err.message : "internal error" }, 500);
      }
    },
  );
}

/**
 * `Response.json(...)` misbehaves under Next.js 16's turbopack dev build (the handler's
 * promise settles but turbopack reports "No response is returned from route handler").
 * Use `new Response(JSON.stringify(...), { ... })` explicitly instead.
 */
export function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function notFoundVm(vmId: string): Response {
  return jsonResponse({ error: `vm not found: ${vmId}` }, 404);
}

function requiresBrowserMutationProtection(method: string, bearer: StackBearer | null): boolean {
  if (!["POST", "PUT", "PATCH", "DELETE"].includes(method.toUpperCase())) {
    return false;
  }
  return bearer === null;
}

function browserMutationOriginAllowed(request: Request): boolean {
  const origin = request.headers.get("origin")?.trim();
  const secFetchSite = request.headers.get("sec-fetch-site")?.trim().toLowerCase();

  if (secFetchSite === "cross-site") return false;
  if (!origin) return false;

  const requestOrigin = requestURLOrigin(request);
  if (requestOrigin && origin === requestOrigin) return true;
  return allowedBrowserOrigins().has(origin);
}

function requestURLOrigin(request: Request): string | null {
  try {
    return new URL(request.url).origin;
  } catch {
    return null;
  }
}

let cachedAllowedOriginsEnv: string | undefined;
let cachedAllowedOrigins: Set<string> | null = null;

// CMUX_VM_ALLOWED_ORIGINS is a comma-separated list of full origins that must match
// the Origin header exactly, for example `https://app.example.com,https://staging.example.com`.
// Do not include paths, schemeless hosts, or trailing slashes.
function allowedBrowserOrigins(): Set<string> {
  const raw = process.env.CMUX_VM_ALLOWED_ORIGINS;
  if (cachedAllowedOrigins && cachedAllowedOriginsEnv === raw) return cachedAllowedOrigins;
  cachedAllowedOriginsEnv = raw;
  const configured = raw?.split(",") ?? [];
  cachedAllowedOrigins = new Set(
    configured
      .map((origin) => origin.trim())
      .filter((origin) => origin.length > 0),
  );
  return cachedAllowedOrigins;
}
