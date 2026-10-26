export type ErrorCode =
  | "bad_request"
  | "unauthorized"
  | "not_found"
  | "bad_signature"
  | "stale_timestamp"
  | "replay"
  | "device_removed"
  | "device_key_mismatch"
  | "not_shared"
  | "permission_none"
  | "scope_exceeds_permission"
  | "host_offline"
  | "not_host"
  | "session_not_pending"
  | "session_not_active"
  | "ticket_invalid"
  | "role_taken"
  | "rate_limited"
  | "internal";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: ErrorCode,
    message: string,
  ) {
    super(message);
  }
}

export const badRequest = (m: string) => new ApiError(400, "bad_request", m);
export const unauthorized = (m: string) => new ApiError(401, "unauthorized", m);
export const notFound = (m = "not found") => new ApiError(404, "not_found", m);

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...headers },
  });
}

export function errorResponse(err: unknown): Response {
  if (err instanceof ApiError) return json({ error: { code: err.code, message: err.message } }, err.status);
  console.error("device-hub internal error", err instanceof Error ? err.stack ?? err.message : String(err));
  return json({ error: { code: "internal", message: "internal error" } }, 500);
}
