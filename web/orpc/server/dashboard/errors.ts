import { ORPCError } from "@orpc/server";
import { TeamApiError, TeamGoneError, TeamServiceUnavailableError } from "@/services/teams/errors";
import type { DashboardErrorCode, DashboardRefusal } from "./error-map";

export { DASHBOARD_ERRORS, TEAM_ERRORS, type DashboardErrorCode, type DashboardRefusal } from "./error-map";

const CODE_BY_STATUS: Readonly<Record<number, DashboardErrorCode>> = {
  400: "BAD_REQUEST",
  401: "UNAUTHORIZED",
  403: "FORBIDDEN",
  402: "PAYMENT_REQUIRED",
  404: "NOT_FOUND",
  409: "CONFLICT",
  410: "GONE",
  413: "PAYLOAD_TOO_LARGE",
  429: "RATE_LIMITED",
  501: "NOT_IMPLEMENTED",
  502: "BAD_GATEWAY",
  503: "UNAVAILABLE",
};

/**
 * The typed error for a refusal with `status` and route error `reason`.
 * Statuses outside the contract become an undeclared internal error, which
 * the client treats as a generic failure.
 */
export function dashboardRefusal(status: number, reason: string, message?: string): ORPCError<string, unknown> {
  const code = CODE_BY_STATUS[status];
  const data: DashboardRefusal = message ? { reason, message } : { reason };
  if (!code) return new ORPCError("INTERNAL_SERVER_ERROR", { status: 500, message: message ?? reason });
  return new ORPCError(code, { status, data, message: message ?? reason });
}

/**
 * Translate an API error response into its typed refusal. Every route family
 * answers `{ error: "code" }` or `{ error: { code, message } }`; VM routes add
 * a top-level `message`.
 */
export async function refusalFromResponse(response: Response): Promise<ORPCError<string, unknown>> {
  const body: unknown = await response.clone().json().catch(() => null);
  const { reason, message } = reasonFromBody(body, response.status);
  return dashboardRefusal(response.status, reason, message);
}

function reasonFromBody(body: unknown, status: number): { reason: string; message?: string } {
  const record = isRecord(body) ? body : {};
  const error = record.error;
  const topMessage = typeof record.message === "string" ? record.message : undefined;
  if (typeof error === "string") return { reason: error, message: topMessage };
  if (isRecord(error) && typeof error.code === "string") {
    return { reason: error.code, message: typeof error.message === "string" ? error.message : topMessage };
  }
  return { reason: `http_${status}`, message: topMessage };
}

/** Map the team services' refusals the same way `runTeamRoute` does. */
export function teamRefusalFromError(error: unknown): unknown {
  if (error instanceof TeamApiError) return dashboardRefusal(error.status, error.code, error.message);
  if (error instanceof TeamGoneError) return dashboardRefusal(403, "team_not_found");
  if (error instanceof TeamServiceUnavailableError) return dashboardRefusal(503, "service_unavailable");
  return error;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
