import * as Data from "effect/Data";
import * as Effect from "effect/Effect";

export type ShareRateLimitCheck = (
  id: string,
  options: { request: Request; rateLimitKey?: string },
) => Promise<{ rateLimited: boolean; error?: string | null }>;

export class ShareConfigurationError extends Data.TaggedError(
  "ShareConfigurationError",
)<{
  readonly code: "share_not_configured";
}> {}

export class ShareRateLimitError extends Data.TaggedError(
  "ShareRateLimitError",
)<{
  readonly code: "rate_limited" | "rate_limit_unavailable";
  readonly retryAfterSeconds?: number;
}> {}

/**
 * Match the relay routes' firewall policy for blocker and availability
 * failures. Share grants are stricter about configuration: a Vercel runtime
 * with a signing key reaches this boundary only when minting is enabled, so a
 * missing limiter id fails closed.
 */
export function enforceShareRateLimit(input: {
  readonly request: Request;
  /**
   * Omit this for Vercel's request-IP boundary. Account-scoped checks pass a
   * stable authenticated key so activity shares the intended budget.
   */
  readonly rateLimitKey?: string;
  readonly ruleId: string | undefined;
  readonly check: ShareRateLimitCheck;
  readonly isVercel: boolean;
  readonly retryAfterSeconds?: number;
}): Effect.Effect<void, ShareRateLimitError> {
  if (!input.isVercel) return Effect.void;
  const ruleId = input.ruleId?.trim();
  if (!ruleId) {
    return Effect.fail(
      new ShareRateLimitError({ code: "rate_limit_unavailable" }),
    );
  }
  return Effect.tryPromise({
    try: () =>
      input.check(ruleId, {
        request: input.request,
        ...(input.rateLimitKey
          ? { rateLimitKey: input.rateLimitKey }
          : {}),
      }),
    catch: () =>
      new ShareRateLimitError({ code: "rate_limit_unavailable" }),
  }).pipe(
    Effect.flatMap(({ rateLimited, error }) => {
      if (rateLimited || error === "blocked") {
        const retryAfterSeconds = input.retryAfterSeconds;
        return Effect.fail(new ShareRateLimitError({
          code: "rate_limited",
          ...(retryAfterSeconds !== undefined &&
            Number.isSafeInteger(retryAfterSeconds) &&
            retryAfterSeconds >= 1 &&
            retryAfterSeconds <= 3_600
            ? { retryAfterSeconds }
            : {}),
        }));
      }
      if (error === "not-found") {
        return Effect.fail(
          new ShareRateLimitError({ code: "rate_limit_unavailable" }),
        );
      }
      if (error) {
        return Effect.fail(
          new ShareRateLimitError({ code: "rate_limit_unavailable" }),
        );
      }
      return Effect.void;
    }),
  );
}

export function requireShareSigningKey<A>(
  key: A | null,
): Effect.Effect<A, ShareConfigurationError> {
  return key === null
    ? Effect.fail(new ShareConfigurationError({ code: "share_not_configured" }))
    : Effect.succeed(key);
}

export async function runShareEffect<A, E>(
  program: Effect.Effect<A, E>,
): Promise<A> {
  const result = await Effect.runPromise(Effect.either(program));
  if (result._tag === "Left") throw result.left;
  return result.right;
}

export function shareErrorResponse(error: unknown): Response {
  const tag = (error as { _tag?: string } | null)?._tag;
  if (tag === "ShareRateLimitError") {
    const typed = error as ShareRateLimitError;
    return jsonResponse(
      { error: typed.code },
      typed.code === "rate_limited" ? 429 : 503,
      typed.code === "rate_limited" &&
        typed.retryAfterSeconds !== undefined
        ? { "retry-after": String(typed.retryAfterSeconds) }
        : undefined,
    );
  }
  if (tag === "ShareConfigurationError") {
    return jsonResponse(
      { error: (error as ShareConfigurationError).code },
      503,
    );
  }
  // Token and key material can be present in unexpected crypto failures.
  // Preserve an operational signal without logging the error or request.
  console.error("share.api.unexpected", { failure: "unexpected" });
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
