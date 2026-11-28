import * as Effect from "effect/Effect";
import { createHash, randomUUID } from "node:crypto";

import {
  RelayAuthenticationError,
  RelayConfigurationError,
  RelayRateLimitError,
  RelayDatabaseError,
  relayDatabaseFailureMetadata,
  type RelayRateLimitSource,
  type RelayServiceError,
} from "./errors";
import { reportMissingRateLimitRule } from "../rateLimitObservability";

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
  /** Correlates ingress-limit events with the originating API request. */
  readonly requestId?: string;
  readonly accountId: string;
  /**
   * Override the key sent to Vercel. `null` deliberately omits the override,
   * making Vercel use the request IP for a cheap pre-auth ingress gate.
   */
  readonly rateLimitKey?: string | null;
  /**
   * Optional per-device partition (endpoint id). When present the budget is
   * per account+device, so one storming device cannot starve the account's
   * other phones, simulators, and tagged builds.
   */
  readonly devicePartition?: string;
  /** Server-owned deployment scope, keeping dev/staging budgets out of production. */
  readonly deploymentPartition?: string;
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
    // No configured rule means the operator wants no rate limiting. Failing
    // here would turn a deliberately-unset env var into a relay outage.
    return Effect.sync(() => {
      void reportMissingRateLimitRule({ route: "relay", reason: "unset" });
    });
  }
  const rateLimitKey = input.rateLimitKey === null
    ? undefined
    : input.rateLimitKey ?? [
      input.deploymentPartition,
      input.accountId,
      input.devicePartition,
    ].filter((part): part is string => Boolean(part)).join(":");
  return Effect.tryPromise({
    try: () => input.check(ruleId, {
      request: input.request,
      ...(rateLimitKey === undefined ? {} : { rateLimitKey }),
    }),
    catch: () => new RelayRateLimitError({ code: "rate_limit_unavailable" }),
  }).pipe(
    Effect.flatMap(({ rateLimited, error }) => {
      if (rateLimited || error === "blocked") {
        const source: RelayRateLimitSource = input.rateLimitKey === null
          ? "ingress_ip"
          : input.devicePartition
            ? "device_budget"
            : "account_budget";
        console.warn("relay.rate_limited", {
          source,
          ruleId,
          ...(rateLimitKey === undefined
            ? {}
            : { partitionHash: createHash("sha256").update(rateLimitKey).digest("hex").slice(0, 16) }),
          ...(input.requestId ? { requestId: input.requestId } : {}),
        });
        const retryAfterSeconds = input.retryAfterSeconds;
        return Effect.fail(new RelayRateLimitError({
          code: "rate_limited",
          source,
          ...(retryAfterSeconds !== undefined &&
          Number.isSafeInteger(retryAfterSeconds) &&
          retryAfterSeconds >= 1 &&
          retryAfterSeconds <= 3_600
            ? { retryAfterSeconds }
            : {}),
        }));
      }
      if (error === "not-found") {
        // The configured rule no longer exists (Vercel returns 404). That
        // means the operator deleted the limit, so treat it as "no limit" and
        // fail open rather than 503-ing every request. Genuine unavailability
        // (a thrown check or an unexpected status) still fails closed below.
        return Effect.sync(() => {
          void reportMissingRateLimitRule({ route: "relay", reason: "not-found" });
        });
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

export type RelayErrorContext = { readonly requestId?: string };

export function relayErrorResponse(
  error: unknown,
  context: RelayErrorContext = {},
): Response {
  const tag = (error as { _tag?: string } | null)?._tag;
  if (tag === "RelayAuthenticationError") {
    return authenticationErrorResponse(error as RelayAuthenticationError, context);
  }
  if (tag === "RelayRateLimitError") {
    return rateLimitErrorResponse(error as RelayRateLimitError, context);
  }
  if (tag === "RelayPreferenceValidationError") {
    return preferenceValidationResponse(
      error as Extract<RelayServiceError, { _tag: "RelayPreferenceValidationError" }>,
    );
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
  if (tag === "RelayCatalogRollbackError" || tag === "RelayCatalogIntegrityError") {
    return catalogErrorResponse(error as CatalogError);
  }
  if (tag === "RelayDatabaseError") {
    return databaseErrorResponse(error as RelayDatabaseError, context);
  }
  if (tag === "RelayConfigurationError" || tag === "RelaySigningError") {
    return unavailablePolicyResponse(tag);
  }
  // Unexpected errors can carry database causes, relay origins, or credentials.
  // Keep the operational event while making its payload intentionally coarse.
  console.error("relay.policy.unexpected", { failure: "unexpected" });
  return jsonResponse({ error: "internal_error" }, 500);
}

function authenticationErrorResponse(
  error: RelayAuthenticationError,
  context: RelayErrorContext,
): Response {
  const rateLimited = error.code === "rate_limited";
  const source = rateLimited ? { source: "auth_provider" } : {};
  const requestId = context.requestId ?? randomUUID();
  console.error("relay.auth.unavailable", { reason: error.code, requestId });
  return jsonResponse(
    { error: rateLimited ? "rate_limited" : "authentication_unavailable", ...source },
    rateLimited ? 429 : 503,
    error.retryAfterSeconds === undefined
      ? undefined
      : {
        "retry-after": String(error.retryAfterSeconds),
        "x-cmux-request-id": requestId,
      },
  );
}

function rateLimitErrorResponse(
  error: RelayRateLimitError,
  context: RelayErrorContext,
): Response {
  const requestId = context.requestId ?? randomUUID();
  const headers = error.code === "rate_limited" && error.retryAfterSeconds !== undefined
    ? {
      "retry-after": String(error.retryAfterSeconds),
      "x-cmux-request-id": requestId,
    }
    : undefined;
  return jsonResponse(
    { error: error.code, ...(error.source ? { source: error.source } : {}) },
    error.code === "rate_limited" ? 429 : 503,
    headers,
  );
}

type CatalogError = Extract<
  RelayServiceError,
  { _tag: "RelayCatalogRollbackError" | "RelayCatalogIntegrityError" }
>;

function catalogErrorResponse(error: CatalogError): Response {
  if (error._tag === "RelayCatalogRollbackError") {
    console.error("relay.policy.catalog_rollback", {
      configuredSequence: error.configuredSequence,
      persistedSequence: error.persistedSequence,
      reason: error.reason,
    });
  } else {
    console.error("relay.policy.catalog_integrity", { reason: error.reason });
  }
  return jsonResponse({ error: "relay_policy_unavailable" }, 503);
}

function preferenceValidationResponse(
  error: Extract<RelayServiceError, { _tag: "RelayPreferenceValidationError" }>,
): Response {
  return jsonResponse({
    error: error.code,
    ...(error.relayIds ? { relayIds: error.relayIds } : {}),
  }, 400);
}

function databaseErrorResponse(error: RelayDatabaseError, context: RelayErrorContext): Response {
  const requestId = context.requestId ?? randomUUID();
  console.error("relay.policy.database_unavailable", {
    ...relayDatabaseFailureMetadata(error),
    requestId,
  });
  return jsonResponse(
    { error: "relay_policy_unavailable", requestId },
    503,
    { "retry-after": "15", "x-cmux-request-id": requestId },
  );
}

function unavailablePolicyResponse(tag: string): Response {
  console.error("relay.policy.unavailable", tag);
  return jsonResponse({ error: "relay_policy_unavailable" }, 503);
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
