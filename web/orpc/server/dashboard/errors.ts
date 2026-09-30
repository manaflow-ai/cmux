import { ORPCError } from "@orpc/server";
import { z } from "zod";
import { TeamApiError, TeamGoneError, TeamServiceUnavailableError, type TeamErrorCode } from "@/services/teams/errors";

/**
 * The typed refusals every dashboard procedure can return. The oRPC `code`
 * carries the HTTP status class; `data.reason` is the route's own error code
 * (`not_found`, `no_teams`, `authorization_unavailable`, ...), so a screen
 * can branch on a status class or on one specific reason.
 */
const refusal = z.object({
  reason: z.string(),
  message: z.string().optional(),
});

export type DashboardRefusal = z.output<typeof refusal>;

export const DASHBOARD_ERRORS = {
  BAD_REQUEST: { status: 400, data: refusal },
  UNAUTHORIZED: { status: 401, data: refusal },
  FORBIDDEN: { status: 403, data: refusal },
  NOT_FOUND: { status: 404, data: refusal },
  CONFLICT: { status: 409, data: refusal },
  PAYLOAD_TOO_LARGE: { status: 413, data: refusal },
  RATE_LIMITED: { status: 429, data: refusal },
  BAD_GATEWAY: { status: 502, data: refusal },
  UNAVAILABLE: { status: 503, data: refusal },
} as const;

export type DashboardErrorCode = keyof typeof DASHBOARD_ERRORS;

export const TEAM_ERROR_CODES = [
  "unauthorized",
  "authentication_unavailable",
  "forbidden",
  "team_not_found",
  "permission_unavailable",
  "invalid_request",
  "payload_too_large",
  "rate_limited",
  "rate_limit_unavailable",
  "last_admin",
  "member_not_found",
  "invitation_not_found",
  "invitation_invalid",
  "email_mismatch",
  "link_not_found",
  "link_invalid",
  "team_has_active_subscription",
  "service_unavailable",
] as const satisfies readonly TeamErrorCode[];

// Every TeamErrorCode is listed: adding a code without listing it fails here.
type MissingTeamCodes = Exclude<TeamErrorCode, (typeof TEAM_ERROR_CODES)[number]>;
const teamCodesComplete: MissingTeamCodes extends never ? true : never = true;
void teamCodesComplete;

const teamRefusal = z.object({
  reason: z.enum(TEAM_ERROR_CODES),
  message: z.string().optional(),
});

/** Team procedures narrow `reason` to the closed team error vocabulary. */
export const TEAM_ERRORS = {
  BAD_REQUEST: { status: 400, data: teamRefusal },
  UNAUTHORIZED: { status: 401, data: teamRefusal },
  FORBIDDEN: { status: 403, data: teamRefusal },
  NOT_FOUND: { status: 404, data: teamRefusal },
  CONFLICT: { status: 409, data: teamRefusal },
  PAYLOAD_TOO_LARGE: { status: 413, data: teamRefusal },
  RATE_LIMITED: { status: 429, data: teamRefusal },
  UNAVAILABLE: { status: 503, data: teamRefusal },
} as const;

const CODE_BY_STATUS: Readonly<Record<number, DashboardErrorCode>> = {
  400: "BAD_REQUEST",
  401: "UNAUTHORIZED",
  403: "FORBIDDEN",
  404: "NOT_FOUND",
  409: "CONFLICT",
  413: "PAYLOAD_TOO_LARGE",
  429: "RATE_LIMITED",
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
