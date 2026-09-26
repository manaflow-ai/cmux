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
  const parts: string[] = [];
  let current: unknown = error;
  for (let depth = 0; current !== undefined && current !== null && depth < 4; depth += 1) {
    const rawName = current instanceof Error ? current.name : typeof current;
    const name = ["Error", "TypeError", "RangeError", "SyntaxError", "DrizzleError", "DrizzleQueryError", "ZodError"].includes(rawName) ? rawName : "Error";
    const text = current instanceof Error ? current.message : String(current);
    const marker = FAILURE_MARKERS.find(([needle]) => text.includes(needle))?.[1];
    // Workers runtime errors carry these booleans; they name the platform
    // failure class without exposing the message text.
    const flags = ["retryable", "overloaded", "remote"].filter(flag => current !== null && typeof current === "object" && Reflect.get(current, flag) === true);
    parts.push([marker ? `${name}:${marker}` : name, ...flags].join("+"));
    current = current instanceof Error ? current.cause : undefined;
  }
  return parts.join(" <- ").slice(0, 200);
}

/**
 * Known failure texts mapped to fixed tags. Storage guards raise the first
 * group; the rest are Workers and Durable Object runtime failures. Only the
 * tag is recorded, never the matched message.
 */
const FAILURE_MARKERS: readonly (readonly [string, string])[] = [
  ["socket_output_capacity", "socket_output_capacity"], ["socket_capacity", "socket_capacity"],
  ["audit_limit", "audit_limit"], ["device_limit", "device_limit"], ["storage_limit", "storage_limit"],
  ["SQLITE_BUSY", "sqlite_busy"], ["SQLITE_FULL", "sqlite_full"], ["CONSTRAINT", "sqlite_constraint"],
  ["code was updated", "do_code_updated"], ["Durable Object reset", "do_reset"],
  ["Network connection lost", "network_lost"], ["overloaded", "overloaded"],
  ["exceeded timeout", "storage_timeout"], ["memory limit", "memory_limit"], ["CPU time", "cpu_limit"],
  ["transient issue", "do_transient"], ["too many subrequests", "subrequest_limit"],
  ["The operation was aborted", "aborted"], ["timed out", "timed_out"], ["fetch failed", "fetch_failed"],
];

/** Telemetry fields for a failure: a cause only when the error was not classified. */
export function failureDiagnostics(error: unknown): { cause?: string } {
  return error instanceof OperationError ? {} : { cause: errorSummary(error) };
}
