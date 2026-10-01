import { z } from "zod";
import type { TeamErrorCode } from "@/services/teams/errors";

// Zod only: the dashboard client imports this module at runtime.

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
  PAYMENT_REQUIRED: { status: 402, data: refusal },
  CONFLICT: { status: 409, data: refusal },
  GONE: { status: 410, data: refusal },
  PAYLOAD_TOO_LARGE: { status: 413, data: refusal },
  RATE_LIMITED: { status: 429, data: refusal },
  BAD_GATEWAY: { status: 502, data: refusal },
  NOT_IMPLEMENTED: { status: 501, data: refusal },
  UNAVAILABLE: { status: 503, data: refusal },
} as const;

export type DashboardErrorCode = keyof typeof DASHBOARD_ERRORS;

export function isDashboardErrorCode(code: string): code is DashboardErrorCode {
  return Object.hasOwn(DASHBOARD_ERRORS, code);
}

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
  "seat_limit",
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
  PAYMENT_REQUIRED: { status: 402, data: teamRefusal },
  CONFLICT: { status: 409, data: teamRefusal },
  GONE: { status: 410, data: teamRefusal },
  PAYLOAD_TOO_LARGE: { status: 413, data: teamRefusal },
  RATE_LIMITED: { status: 429, data: teamRefusal },
  UNAVAILABLE: { status: 503, data: teamRefusal },
} as const;
