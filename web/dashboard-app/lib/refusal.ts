import { ORPCError } from "@orpc/client";
import { type DashboardErrorCode, isDashboardErrorCode } from "@/orpc/server/dashboard/error-map";

/** A declared refusal from a dashboard procedure. */
export type DashboardRefusal = {
  readonly code: DashboardErrorCode;
  readonly status: number;
  /** The route's own error code, e.g. `no_teams` or `last_admin`. */
  readonly reason: string;
  readonly message: string | undefined;
};

/**
 * The declared refusal `error` carries, or null for a network failure or an
 * undeclared server error. Declared errors were validated against the
 * procedure's error map on the server, so `data.reason` is always present.
 */
export function dashboardRefusal(error: unknown): DashboardRefusal | null {
  if (!(error instanceof ORPCError) || !error.defined || !isDashboardErrorCode(error.code)) return null;
  const data: unknown = error.data;
  const reason = typeof data === "object" && data !== null && "reason" in data && typeof data.reason === "string"
    ? data.reason
    : error.code.toLowerCase();
  const message = typeof data === "object" && data !== null && "message" in data && typeof data.message === "string"
    ? data.message
    : undefined;
  return { code: error.code, status: error.status, reason, message };
}

/** True for a declared refusal, optionally with this HTTP status. */
export function isRefusal(error: unknown, status?: number): boolean {
  const refusal = dashboardRefusal(error);
  return refusal !== null && (status === undefined || refusal.status === status);
}

/** The route error code of a declared refusal, else null. */
export function refusalReason(error: unknown): string | null {
  return dashboardRefusal(error)?.reason ?? null;
}
