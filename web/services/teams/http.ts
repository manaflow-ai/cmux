import type { z } from "zod";
import { readBoundedJsonRecord } from "../subrouter/boundedJson";
import { hasAuthRateLimitSignal } from "../vms/authErrors";
import { verifyRequest, type AuthedUser } from "../vms/auth";
import {
  browserMutationOriginAllowed,
  jsonResponse,
  parseBearer,
  requiresBrowserMutationProtection,
} from "../vms/routeHelpers";
import { TeamApiError, teamErrorResponse, TeamServiceUnavailableError } from "./errors";

export const TEAM_REQUEST_BODY_LIMIT_BYTES = 16 * 1024;

export type TeamRouteAuth =
  | { readonly ok: true; readonly user: AuthedUser }
  | { readonly ok: false; readonly response: Response };

export type TeamRouteDependencies = {
  readonly verify?: (request: Request) => Promise<AuthedUser | null>;
};

/**
 * Cookie or native-token auth for every team route. Browser mutations must
 * come from an allowed origin; native bearer clients are exempt, as on the
 * VM routes.
 */
export async function authenticateTeamRequest(
  request: Request,
  dependencies: TeamRouteDependencies = {},
): Promise<TeamRouteAuth> {
  if (
    requiresBrowserMutationProtection(request.method, parseBearer(request)) &&
    !browserMutationOriginAllowed(request)
  ) {
    return { ok: false, response: teamErrorResponse("forbidden", 403) };
  }
  let user: AuthedUser | null;
  try {
    user = await (dependencies.verify ?? ((value) => verifyRequest(value)))(request);
  } catch (error) {
    const rateLimited = hasAuthRateLimitSignal(error);
    console.error("team route authentication unavailable", { rateLimited });
    return {
      ok: false,
      response: rateLimited
        ? teamErrorResponse("rate_limited", 429, { headers: { "retry-after": "30" } })
        : teamErrorResponse("authentication_unavailable", 503, { headers: { "retry-after": "5" } }),
    };
  }
  if (!user || user.isAnonymous) return { ok: false, response: teamErrorResponse("unauthorized", 401) };
  return { ok: true, user };
}

export type TeamJsonBody<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly response: Response };

/** Read a JSON object of at most 16 KB and validate it. */
export async function readTeamJson<T>(request: Request, schema: z.ZodType<T>): Promise<TeamJsonBody<T>> {
  const body = await readBoundedJsonRecord(request, TEAM_REQUEST_BODY_LIMIT_BYTES);
  if (!body.ok) {
    return {
      ok: false,
      response: body.status === 413
        ? teamErrorResponse("payload_too_large", 413)
        : teamErrorResponse("invalid_request", 400, { message: "The request body must be a JSON object." }),
    };
  }
  const parsed = schema.safeParse(body.value);
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    const path = issue?.path.length ? `${issue.path.join(".")}: ` : "";
    return {
      ok: false,
      response: teamErrorResponse("invalid_request", 400, { message: `${path}${issue?.message ?? "Invalid request."}` }),
    };
  }
  return { ok: true, value: parsed.data };
}

/** Translate service refusals; log and hide everything unexpected. */
export async function runTeamRoute(route: string, handler: () => Promise<Response>): Promise<Response> {
  try {
    return await handler();
  } catch (error) {
    if (error instanceof TeamApiError) return error.toResponse();
    if (error instanceof TeamServiceUnavailableError) {
      console.error("team route dependency unavailable", { route });
      return teamErrorResponse("service_unavailable", 503, { headers: { "retry-after": "5" } });
    }
    console.error("team route failed", { route, errorType: error instanceof Error ? error.name : typeof error });
    return jsonResponse({ error: { code: "internal_error", message: "The request failed unexpectedly." } }, 500);
  }
}
