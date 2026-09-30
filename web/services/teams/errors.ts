import { jsonResponse } from "../vms/routeHelpers";

/** Every team API error code. Messages are English and for developers. */
export type TeamErrorCode =
  | "unauthorized"
  | "authentication_unavailable"
  | "forbidden"
  | "team_not_found"
  | "permission_unavailable"
  | "invalid_request"
  | "payload_too_large"
  | "rate_limited"
  | "rate_limit_unavailable"
  | "last_admin"
  | "member_not_found"
  | "invitation_not_found"
  | "invitation_invalid"
  | "email_mismatch"
  | "link_not_found"
  | "link_invalid"
  | "team_has_active_subscription"
  | "service_unavailable";

const DEFAULT_MESSAGES: Record<TeamErrorCode, string> = {
  unauthorized: "Sign in to continue.",
  authentication_unavailable: "Authentication is temporarily unavailable.",
  forbidden: "You do not have permission to do this.",
  team_not_found: "Team not found.",
  permission_unavailable: "Team permissions are temporarily unavailable.",
  invalid_request: "The request is invalid.",
  payload_too_large: "The request body is too large.",
  rate_limited: "Too many requests. Try again later.",
  rate_limit_unavailable: "Rate limiting is temporarily unavailable.",
  last_admin: "A team must keep at least one admin.",
  member_not_found: "Member not found.",
  invitation_not_found: "Invitation not found.",
  invitation_invalid: "This invitation is invalid, expired, or already used.",
  email_mismatch: "This invitation was sent to a different email address.",
  link_not_found: "Invite link not found.",
  link_invalid: "This invite link is invalid, expired, revoked, or full.",
  team_has_active_subscription: "Cancel the team subscription before deleting the team.",
  service_unavailable: "The service is temporarily unavailable.",
};

/** `{ error: { code, message } }`, the one error shape of the team API. */
export function teamErrorResponse(
  code: TeamErrorCode,
  status: number,
  options: { readonly message?: string; readonly headers?: Readonly<Record<string, string>> } = {},
): Response {
  return jsonResponse(
    { error: { code, message: options.message ?? DEFAULT_MESSAGES[code] } },
    status,
    { "cache-control": "no-store", ...options.headers },
  );
}

/** A refusal a service raises for its route to translate into a response. */
export class TeamApiError extends Error {
  override readonly name = "TeamApiError";
  constructor(
    readonly code: TeamErrorCode,
    readonly status: number,
    message?: string,
  ) {
    super(message ?? DEFAULT_MESSAGES[code]);
  }

  toResponse(): Response {
    return teamErrorResponse(this.code, this.status, { message: this.message });
  }
}

/** Stack or the database did not answer; the caller may retry. */
export class TeamServiceUnavailableError extends Error {
  override readonly name = "TeamServiceUnavailableError";
}

/** Stack reported that the team no longer exists (deleted mid-request). */
export class TeamGoneError extends Error {
  override readonly name = "TeamGoneError";
}
