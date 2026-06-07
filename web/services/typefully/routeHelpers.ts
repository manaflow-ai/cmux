import { type Span } from "@opentelemetry/api";
import { recordSpanError, withApiRouteSpan, type MaybeAttributes } from "../telemetry";
import {
  requireTypefullyUserFromRequest,
  type TypefullyAccessDeniedReason,
  type TypefullyUser,
} from "./auth";
import {
  isTypefullyDatabaseError,
  isTypefullyDraftNotFoundError,
} from "./errors";

export type AuthedTypefullyRouteContext = {
  readonly user: TypefullyUser;
  readonly span: Span;
};

export async function withAuthedTypefullyApiRoute(
  request: Request,
  route: string,
  attributes: MaybeAttributes,
  handler: (context: AuthedTypefullyRouteContext) => Promise<Response>,
): Promise<Response> {
  return withApiRouteSpan(
    request,
    route,
    { "cmux.subsystem": "typefully-lite", ...attributes },
    async (span) => {
      try {
        const access = await requireTypefullyUserFromRequest(request);
        if (!access.ok) {
          return typefullyAuthErrorResponse(access.reason, access.email);
        }
        if (requiresBrowserMutationProtection(request.method) && !browserMutationOriginAllowed(request)) {
          return jsonResponse({ error: "forbidden" }, 403);
        }
        return await handler({ user: access.user, span });
      } catch (err) {
        recordSpanError(span, err);
        console.error(`typefully route failed: ${route}`, err);
        const workflowError = typefullyWorkflowErrorResponse(err);
        if (workflowError) return workflowError;
        return jsonResponse({
          error: "typefully_internal_error",
          message: "Draft request failed unexpectedly.",
        }, 500);
      }
    },
  );
}

export function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function typefullyAuthErrorResponse(
  reason: TypefullyAccessDeniedReason,
  email?: string | null,
): Response {
  const status = reason === "unauthenticated" ? 401 : 403;
  return jsonResponse({
    error: reason,
    message: typefullyAuthMessage(reason, email),
  }, status);
}

function typefullyAuthMessage(
  reason: TypefullyAccessDeniedReason,
  email?: string | null,
): string {
  switch (reason) {
    case "auth_not_configured":
      return "Authentication is not configured.";
    case "unauthenticated":
      return "Sign in with Google to save drafts.";
    case "email_missing":
      return "Your account does not have a primary email.";
    case "email_unverified":
      return `${email ?? "This email"} is not verified.`;
    case "domain_not_allowed":
      return `${email ?? "This email"} is not allowed. Use a manaflow.com, manaflow.ai, or cmux.com account.`;
    case "google_required":
      return "This workspace only allows Google sign-in.";
  }
}

function typefullyWorkflowErrorResponse(err: unknown): Response | null {
  if (isTypefullyDraftNotFoundError(err)) {
    return jsonResponse({
      error: "draft_not_found",
      message: "Draft not found.",
    }, 404);
  }

  if (isTypefullyDatabaseError(err)) {
    return jsonResponse({
      error: "draft_storage_unavailable",
      message: "Draft storage is temporarily unavailable.",
    }, 503);
  }

  return null;
}

function requiresBrowserMutationProtection(method: string): boolean {
  return ["POST", "PUT", "PATCH", "DELETE"].includes(method.toUpperCase());
}

function browserMutationOriginAllowed(request: Request): boolean {
  const origin = request.headers.get("origin")?.trim();
  const secFetchSite = request.headers.get("sec-fetch-site")?.trim().toLowerCase();
  if (secFetchSite === "cross-site") return false;
  if (!origin) return false;

  const requestOrigin = requestURLOrigin(request);
  return Boolean(requestOrigin && origin === requestOrigin);
}

function requestURLOrigin(request: Request): string | null {
  try {
    return new URL(request.url).origin;
  } catch {
    return null;
  }
}
