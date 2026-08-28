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
  readonly source?: RelayRateLimitSource;
}> {}

export class RelayAuthenticationError extends Data.TaggedError(
  "RelayAuthenticationError",
)<{
  readonly code: "rate_limited" | "unavailable";
  readonly cause: unknown;
  readonly retryAfterSeconds?: number;
}> {}

/** Which enforcement layer produced a 429; diagnosing the 08-27 incident
 * required hours of elimination because all three were indistinguishable. */
export type RelayRateLimitSource = "ingress_ip" | "device_budget" | "auth_provider";


export class RelaySigningError extends Data.TaggedError("RelaySigningError")<{
  readonly cause: unknown;
}> {}

const MAX_AUTH_ERROR_METADATA_NODES = 64;
const MAX_AUTH_ERROR_METADATA_DEPTH = 8;

/**
 * Convert an auth-provider failure into a coarse, retry-safe relay error.
 * Stack's SDK wraps upstream throttles in AggregateError/RetryError objects,
 * so inspect only bounded error metadata and never serialize the original
 * failure (it can contain bearer or refresh-token details).
 */
export function relayAuthenticationError(cause: unknown): RelayAuthenticationError {
  const rateLimited = hasRateLimitSignal(cause);
  if (rateLimited) {
    console.warn("relay.rate_limited", { source: "auth_provider" });
  }
  return new RelayAuthenticationError({
    code: rateLimited ? "rate_limited" : "unavailable",
    cause,
    ...(rateLimited ? { retryAfterSeconds: 60 } : {}),
  });
}

function hasRateLimitSignal(
  value: unknown,
  state: {
    readonly seen: Set<object>;
    count: number;
  } = { seen: new Set<object>(), count: 0 },
  depth = 0,
): boolean {
  if (depth > MAX_AUTH_ERROR_METADATA_DEPTH) return false;
  if (typeof value === "number") return value === 429;
  if (typeof value === "string") {
    return /rate[\s_-]?limit(?:ed|ing)?|too many requests/i.test(value);
  }
  if (!value || typeof value !== "object") return false;
  if (
    state.count >= MAX_AUTH_ERROR_METADATA_NODES ||
    state.seen.has(value)
  ) return false;
  state.seen.add(value);
  state.count += 1;

  const candidate = value as {
    readonly message?: unknown;
    readonly name?: unknown;
    readonly code?: unknown;
    readonly status?: unknown;
    readonly statusCode?: unknown;
    readonly cause?: unknown;
    readonly errors?: unknown;
  };
  return hasRateLimitSignal(candidate.message, state, depth + 1) ||
    hasRateLimitSignal(candidate.name, state, depth + 1) ||
    hasRateLimitSignal(candidate.code, state, depth + 1) ||
    hasRateLimitSignal(candidate.status, state, depth + 1) ||
    hasRateLimitSignal(candidate.statusCode, state, depth + 1) ||
    hasRateLimitSignal(candidate.cause, state, depth + 1) ||
    (Array.isArray(candidate.errors) && candidate.errors
      .slice(0, MAX_AUTH_ERROR_METADATA_NODES)
      .some((error) => hasRateLimitSignal(error, state, depth + 1)));
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
