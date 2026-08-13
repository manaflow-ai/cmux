import * as Data from "effect/Data";

export class RelayConfigurationError extends Data.TaggedError("RelayConfigurationError")<{
  readonly code:
    | "catalog_not_configured"
    | "catalog_invalid"
    | "signing_key_not_configured"
    | "signing_key_invalid"
    | "credential_set_invalid";
}> {}

export class RelayCatalogRollbackError extends Data.TaggedError("RelayCatalogRollbackError")<{
  readonly configuredSequence: number;
  readonly persistedSequence: number;
  readonly reason:
    | "sequence_regressed"
    | "sequence_reused_with_different_catalog"
    | "previous_catalog_unavailable"
    | "unsafe_transition";
}> {}

export class RelayCatalogIntegrityError extends Data.TaggedError("RelayCatalogIntegrityError")<{
  readonly reason: "persisted_catalog_digest_mismatch";
}> {}

export class RelayDatabaseError extends Data.TaggedError("RelayDatabaseError")<{
  readonly operation: string;
  readonly cause: unknown;
}> {}

export class RelayPreferenceValidationError extends Data.TaggedError(
  "RelayPreferenceValidationError",
)<{
  readonly code:
    | "invalid_preference"
    | "credential_fields_forbidden"
    | "unknown_managed_relay";
  readonly relayIds?: readonly string[];
}> {}

export class RelayPreferenceConflictError extends Data.TaggedError("RelayPreferenceConflictError")<{
  readonly expectedRevision: number;
  readonly currentRevision: number;
}> {}

export class RelayAccountDeletionBlockedError extends Data.TaggedError(
  "RelayAccountDeletionBlockedError",
)<{
  readonly reason: "account_deletion_in_progress";
}> {}

export class RelayRateLimitError extends Data.TaggedError("RelayRateLimitError")<{
  readonly code: "rate_limited" | "rate_limit_unavailable";
  readonly retryAfterSeconds?: number;
}> {}

export class RelayAuthenticationError extends Data.TaggedError(
  "RelayAuthenticationError",
)<{
  readonly code: "rate_limited" | "unavailable";
  readonly cause: unknown;
  readonly retryAfterSeconds?: number;
}> {}

export class RelaySigningError extends Data.TaggedError("RelaySigningError")<{
  readonly cause: unknown;
}> {}

/**
 * Convert an auth-provider failure into a coarse, retry-safe relay error.
 * Stack's SDK wraps upstream throttles in AggregateError/RetryError objects,
 * so inspect only bounded error metadata and never serialize the original
 * failure (it can contain bearer or refresh-token details).
 */
export function relayAuthenticationError(cause: unknown): RelayAuthenticationError {
  const rateLimited = hasRateLimitSignal(cause);
  return new RelayAuthenticationError({
    code: rateLimited ? "rate_limited" : "unavailable",
    cause,
    ...(rateLimited ? { retryAfterSeconds: 60 } : {}),
  });
}

function hasRateLimitSignal(
  value: unknown,
  seen = new Set<object>(),
): boolean {
  if (typeof value === "string") {
    return /rate[\s_-]?limit(?:ed|ing)?/i.test(value);
  }
  if (!value || typeof value !== "object") return false;
  if (seen.has(value)) return false;
  seen.add(value);

  const candidate = value as {
    readonly message?: unknown;
    readonly name?: unknown;
    readonly code?: unknown;
    readonly cause?: unknown;
    readonly errors?: unknown;
  };
  return hasRateLimitSignal(candidate.message, seen) ||
    hasRateLimitSignal(candidate.name, seen) ||
    hasRateLimitSignal(candidate.code, seen) ||
    hasRateLimitSignal(candidate.cause, seen) ||
    (Array.isArray(candidate.errors) && candidate.errors.some((error) =>
      hasRateLimitSignal(error, seen)
    ));
}

export type RelayServiceError =
  | RelayConfigurationError
  | RelayCatalogRollbackError
  | RelayCatalogIntegrityError
  | RelayDatabaseError
  | RelayPreferenceValidationError
  | RelayPreferenceConflictError
  | RelayAccountDeletionBlockedError
  | RelayRateLimitError
  | RelayAuthenticationError
  | RelaySigningError;
