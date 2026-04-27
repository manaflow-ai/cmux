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
        const user = await verifyRequest(request);
        if (!user) return unauthorized();
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
