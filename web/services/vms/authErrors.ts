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

export function hasAuthRateLimitSignal(
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

const TRANSIENT_ERROR_NAMES = new Set([
  "SubrouterAuthorizationTimeoutError",
  "TimeoutError",
  "AbortError",
  // The Stack SDK's answer when every API host failed (outage).
  "ApiUrlsFailedError",
]);

/**
 * Whether a Stack failure is transient: a throttle (429), a Stack 5xx, a
 * timeout, an unreachable host, or our own overload gate behind a slow Stack.
 * Anything else (configuration, a refused session, a bug) is not, and keeps
 * its real handling. Walks a bounded cause chain.
 */
export function isTransientStackFailure(error: unknown): boolean {
  if (hasAuthRateLimitSignal(error)) return true;
  let current: unknown = error;
  for (let depth = 0; depth < MAX_AUTH_ERROR_METADATA_DEPTH && current; depth++) {
    if (typeof current !== "object") return false;
    const candidate = current as { name?: unknown; message?: unknown; status?: unknown; transient?: unknown; cause?: unknown };
    if (candidate.transient === true) return true;
    if (typeof candidate.status === "number" && candidate.status >= 500) return true;
    if (typeof candidate.name === "string" && TRANSIENT_ERROR_NAMES.has(candidate.name)) return true;
    if (candidate.name === "TypeError" && candidate.message === "fetch failed") return true;
    current = candidate.cause;
  }
  return false;
}
