import type { Span } from "@opentelemetry/api";
import { unauthorized, verifyRequest, type AuthedUser } from "../vms/auth";
import { jsonResponse } from "../vms/routeHelpers";
import { recordSpanError, withApiRouteSpan, type MaybeAttributes } from "../telemetry";

export type AuthedHiveRouteContext = {
  user: AuthedUser;
  span: Span;
};

export async function withAuthedHiveApiRoute(
  request: Request,
  route: string,
  attributes: MaybeAttributes,
  failureLog: string,
  handler: (context: AuthedHiveRouteContext) => Promise<Response>,
): Promise<Response> {
  return withApiRouteSpan(
    request,
    route,
    { "cmux.subsystem": "hive", ...attributes },
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

function parseBearer(request: Request): { accessToken: string; refreshToken: string } | null {
  const auth = request.headers.get("authorization");
  const refresh = request.headers.get("x-stack-refresh-token");
  if (!auth?.toLowerCase().startsWith("bearer ") || !refresh) return null;
  const accessToken = auth.slice("bearer ".length).trim();
  const refreshToken = refresh.trim();
  if (!accessToken || !refreshToken) return null;
  return { accessToken, refreshToken };
}

function requiresBrowserMutationProtection(
  method: string,
  bearer: { accessToken: string; refreshToken: string } | null,
): boolean {
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

function allowedBrowserOrigins(): Set<string> {
  const raw = process.env.CMUX_HIVE_ALLOWED_ORIGINS ?? process.env.CMUX_VM_ALLOWED_ORIGINS;
  if (cachedAllowedOrigins && cachedAllowedOriginsEnv === raw) return cachedAllowedOrigins;
  cachedAllowedOriginsEnv = raw;
  cachedAllowedOrigins = new Set(
    (raw?.split(",") ?? [])
      .map((origin) => origin.trim())
      .filter((origin) => origin.length > 0),
  );
  return cachedAllowedOrigins;
}

