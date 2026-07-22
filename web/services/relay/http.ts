import * as Effect from "effect/Effect";

import {
  RelayConfigurationError,
  RelayRateLimitError,
  type RelayServiceError,
} from "./errors";

export type RelayRateLimitCheck = (
  id: string,
  options: { request: Request; rateLimitKey?: string },
) => Promise<{ rateLimited: boolean; error?: string }>;

export async function runRelayEffect<A, E>(
  program: Effect.Effect<A, E>,
): Promise<A> {
  const result = await Effect.runPromise(Effect.either(program));
  if (result._tag === "Left") throw result.left;
  return result.right;
}

export function enforceRelayRateLimit(input: {
  readonly request: Request;
  readonly accountId: string;
  readonly ruleId: string | undefined;
  readonly check: RelayRateLimitCheck;
  readonly isVercel?: boolean;
  readonly retryAfterSeconds?: number;
}): Effect.Effect<void, RelayConfigurationError | RelayRateLimitError> {
  if (!(input.isVercel ?? process.env.VERCEL === "1")) {
    return Effect.void;
  }
  const ruleId = input.ruleId?.trim();
  if (!ruleId) {
    return Effect.fail(
      new RelayConfigurationError({ code: "rate_limit_not_configured" }),
    );
  }
  return Effect.tryPromise({
    try: () => input.check(ruleId, {
      request: input.request,
      rateLimitKey: input.accountId,
    }),
    catch: () => new RelayRateLimitError({ code: "rate_limit_unavailable" }),
  }).pipe(
    Effect.flatMap(({ rateLimited, error }) => {
      if (rateLimited || error === "blocked") {
        const retryAfterSeconds = input.retryAfterSeconds;
        return Effect.fail(new RelayRateLimitError({
          code: "rate_limited",
          ...(retryAfterSeconds !== undefined &&
          Number.isSafeInteger(retryAfterSeconds) &&
          retryAfterSeconds >= 1 &&
          retryAfterSeconds <= 3_600
            ? { retryAfterSeconds }
            : {}),
        }));
      }
      if (error) {
        return Effect.fail(
          new RelayRateLimitError({ code: "rate_limit_unavailable" }),
        );
      }
      return Effect.void;
    }),
  );
}

export function relayErrorResponse(error: unknown): Response {
  const tag = (error as { _tag?: string } | null)?._tag;
  if (tag === "RelayRateLimitError") {
    const code = (error as RelayRateLimitError).code;
    return jsonResponse(
      { error: code },
      code === "rate_limited" ? 429 : 503,
      code === "rate_limited" &&
      (error as RelayRateLimitError).retryAfterSeconds !== undefined
        ? { "retry-after": String((error as RelayRateLimitError).retryAfterSeconds) }
        : undefined,
    );
  }
  if (tag === "RelayPreferenceValidationError") {
    const typed = error as Extract<RelayServiceError, { _tag: "RelayPreferenceValidationError" }>;
    return jsonResponse({
      error: typed.code,
      ...(typed.relayIds ? { relayIds: typed.relayIds } : {}),
    }, 400);
  }
  if (tag === "RelayPreferenceConflictError") {
    const typed = error as Extract<RelayServiceError, { _tag: "RelayPreferenceConflictError" }>;
    return jsonResponse({
      error: "preference_conflict",
      currentRevision: typed.currentRevision,
    }, 409);
  }
  if (tag === "RelayAccountDeletionBlockedError") {
    return jsonResponse({ error: "account_deletion_in_progress" }, 409);
  }
  if (tag === "RelayCatalogRollbackError") {
    console.error("relay.policy.catalog_rollback", {
      configuredSequence: (error as { configuredSequence?: unknown }).configuredSequence,
      persistedSequence: (error as { persistedSequence?: unknown }).persistedSequence,
      reason: (error as { reason?: unknown }).reason,
    });
    return jsonResponse({ error: "relay_policy_unavailable" }, 503);
  }
  if (tag === "RelayCatalogIntegrityError") {
    const typed = error as Extract<RelayServiceError, { _tag: "RelayCatalogIntegrityError" }>;
    console.error("relay.policy.catalog_integrity", { reason: typed.reason });
    return jsonResponse({ error: "relay_policy_unavailable" }, 503);
  }
  if (
    tag === "RelayConfigurationError" ||
    tag === "RelayDatabaseError" ||
    tag === "RelaySigningError"
  ) {
    console.error("relay.policy.unavailable", tag);
    return jsonResponse({ error: "relay_policy_unavailable" }, 503);
  }
  // Unexpected errors can carry database causes, relay origins, or credentials.
  // Keep the operational event while making its payload intentionally coarse.
  console.error("relay.policy.unexpected", { failure: "unexpected" });
  return jsonResponse({ error: "internal_error" }, 500);
}

export function jsonResponse(
  data: unknown,
  status = 200,
  extraHeaders?: HeadersInit,
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
      ...Object.fromEntries(new Headers(extraHeaders)),
    },
  });
}
