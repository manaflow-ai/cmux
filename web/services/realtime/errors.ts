import * as Data from "effect/Data";

export class RealtimeConfigurationError extends Data.TaggedError(
  "RealtimeConfigurationError",
)<{
  readonly code: "api_key_not_configured" | "rate_limit_not_configured";
}> {}

export class RealtimeProviderError extends Data.TaggedError(
  "RealtimeProviderError",
)<{
  readonly code:
    | "provider_unavailable"
    | "provider_rejected"
    | "invalid_provider_response";
  readonly status?: number;
}> {}

export class RealtimeRateLimitError extends Data.TaggedError(
  "RealtimeRateLimitError",
)<{
  readonly code: "rate_limited" | "rate_limit_unavailable";
  readonly retryAfterSeconds?: number;
}> {}

export type RealtimeServiceError =
  | RealtimeConfigurationError
  | RealtimeProviderError
  | RealtimeRateLimitError;
