const MAX_AUTH_ERROR_METADATA_NODES = 64;
const MAX_AUTH_ERROR_METADATA_DEPTH = 8;
const AUTH_RETRY_AFTER_SECONDS = 60;

/**
 * Turn a Stack Auth provider failure into a stable API response.
 * Stack's fallback client wraps throttles in AggregateError/RetryError values,
 * so inspect only bounded metadata and never serialize the original error.
 */
export function authProviderErrorResponse(
  cause: unknown,
  route: string,
): Response {
  const rateLimited = hasAuthRateLimitSignal(cause);
  const status = rateLimited ? 429 : 503;
  console.error("Stack Auth provider unavailable", {
    route,
    reason: rateLimited ? "rate_limited" : "unavailable",
  });
  return new Response(
    JSON.stringify({
      error: rateLimited ? "rate_limited" : "authentication_unavailable",
    }),
    {
      status,
      headers: {
        "content-type": "application/json",
        "cache-control": "no-store",
        ...(rateLimited
          ? { "retry-after": String(AUTH_RETRY_AFTER_SECONDS) }
          : {}),
      },
    },
  );
}

function hasAuthRateLimitSignal(
  value: unknown,
  state: { readonly seen: Set<object>; count: number } = {
    seen: new Set<object>(),
    count: 0,
  },
  depth = 0,
): boolean {
  if (depth > MAX_AUTH_ERROR_METADATA_DEPTH) return false;
  if (typeof value === "number") return value === 429;
  if (typeof value === "string") {
    return /rate[\s_-]?limit(?:ed|ing)?|too many requests/i.test(value);
  }
  if (!value || typeof value !== "object") return false;
  if (state.count >= MAX_AUTH_ERROR_METADATA_NODES || state.seen.has(value)) {
    return false;
  }
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
  return hasAuthRateLimitSignal(candidate.message, state, depth + 1) ||
    hasAuthRateLimitSignal(candidate.name, state, depth + 1) ||
    hasAuthRateLimitSignal(candidate.code, state, depth + 1) ||
    hasAuthRateLimitSignal(candidate.status, state, depth + 1) ||
    hasAuthRateLimitSignal(candidate.statusCode, state, depth + 1) ||
    hasAuthRateLimitSignal(candidate.cause, state, depth + 1) ||
    (Array.isArray(candidate.errors) && candidate.errors
      .slice(0, MAX_AUTH_ERROR_METADATA_NODES)
      .some((error) => hasAuthRateLimitSignal(error, state, depth + 1)));
}
