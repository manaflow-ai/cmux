import * as Data from "effect/Data";

export class RelayConfigurationError extends Data.TaggedError("RelayConfigurationError")<{
  readonly code:
    | "catalog_not_configured"
    | "catalog_invalid"
    | "signing_key_not_configured"
    | "signing_key_invalid"
    | "credential_set_invalid"
    | "rate_limit_not_configured";
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

export class RelaySigningError extends Data.TaggedError("RelaySigningError")<{
  readonly cause: unknown;
}> {}

export type RelayServiceError =
  | RelayConfigurationError
  | RelayCatalogRollbackError
  | RelayCatalogIntegrityError
  | RelayDatabaseError
  | RelayPreferenceValidationError
  | RelayPreferenceConflictError
  | RelayAccountDeletionBlockedError
  | RelayRateLimitError
  | RelaySigningError;
