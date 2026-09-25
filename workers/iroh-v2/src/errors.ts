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
 * A bounded diagnostic for an unclassified failure: error names and messages
 * along the cause chain. Quoted text (drizzle embeds the SQL statement) and
 * bound parameters are removed, so no SQL or identifiers reach the sinks.
 */
export function errorSummary(error: unknown): string {
  const parts: string[] = [];
  for (let current = error, depth = 0; current !== undefined && current !== null && depth < 3; depth += 1) {
    const text = current instanceof Error ? `${current.name}: ${current.message}` : String(current);
    parts.push(text.split(/\bparams\b/i)[0]!.replace(/'[\s\S]*'/, "'…'").trim().slice(0, 160));
    current = current instanceof Error ? current.cause : undefined;
  }
  return parts.join(" <- ").slice(0, 400);
}
