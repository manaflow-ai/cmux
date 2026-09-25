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

/**
 * Returns a bounded, allowlisted diagnostic for an unclassified failure.
 * Error messages can contain SQL, identifiers, or request data, so telemetry
 * records only error names and known capacity markers from the cause chain.
 */
export function errorSummary(error: unknown): string {
  const markers = ["socket_output_capacity", "socket_capacity"] as const;
  const parts: string[] = [];
  let current: unknown = error;
  for (let depth = 0; current !== undefined && current !== null && depth < 4; depth += 1) {
    const rawName = current instanceof Error ? current.name : typeof current;
    const name = ["Error", "TypeError", "RangeError", "SyntaxError", "DrizzleError", "DrizzleQueryError"].includes(rawName) ? rawName : "Error";
    const text = current instanceof Error ? current.message : String(current);
    const marker = markers.find(candidate => text.includes(candidate));
    parts.push(marker ? `${name}:${marker}` : name);
    current = current instanceof Error ? current.cause : undefined;
  }
  return parts.join(" <- ").slice(0, 160);
}
