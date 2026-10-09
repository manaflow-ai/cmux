import type { ContentfulStatusCode } from "hono/utils/http-status";

export type ErrorCode =
  | "bad_request"
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "rate_limited"
  | "unavailable"
  | "unsupported"
  | "internal";

const STATUS: Record<ErrorCode, ContentfulStatusCode> = {
  bad_request: 400,
  unauthorized: 401,
  forbidden: 403,
  not_found: 404,
  rate_limited: 429,
  unavailable: 503,
  unsupported: 501,
  internal: 500,
};

export class ApiError extends Error {
  readonly status: ContentfulStatusCode;
  constructor(
    readonly code: ErrorCode,
    message: string,
    status?: ContentfulStatusCode,
  ) {
    super(message);
    this.status = status ?? STATUS[code];
  }
}

export const badRequest = (message: string) => new ApiError("bad_request", message);
export const unauthorized = (message = "unauthorized") => new ApiError("unauthorized", message);
export const notFound = (message = "not found") => new ApiError("not_found", message);
export const unavailable = (message: string) => new ApiError("unavailable", message);
export const unsupported = (message: string) => new ApiError("unsupported", message);

export function errorBody(code: ErrorCode, message: string) {
  return { error: { code, message } };
}
