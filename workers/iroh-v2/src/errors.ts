import type { ErrorCode } from "./contracts/responses";

/** Stable public errors carry no upstream response, credential, or SQL details. */
export class OperationError extends Error {
  constructor(
    readonly code: ErrorCode,
    readonly status: number,
    readonly retryable = false,
    readonly retryAfterMs?: number,
  ) { super(code); }
}

export function publicError(error: unknown): OperationError {
  return error instanceof OperationError ? error : new OperationError("internal_error", 500, true);
}
