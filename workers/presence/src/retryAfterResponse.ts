export const DEFAULT_RETRY_AFTER_SECONDS = 60;

/** Parses both RFC Retry-After forms. A past HTTP date is still a one-second
 * floor so callers never turn a valid server directive into an immediate
 * same-tick retry. */
export function parseRetryAfterSeconds(
  value: string | null,
  nowMs = Date.now(),
): number | undefined {
  if (value === null) return undefined;
  const trimmed = value.trim();
  if (/^\d+$/.test(trimmed)) {
    const seconds = Number(trimmed);
    return Number.isSafeInteger(seconds) ? Math.max(1, seconds) : undefined;
  }
  const retryAt = Date.parse(trimmed);
  if (!Number.isFinite(retryAt)) return undefined;
  return Math.max(1, Math.ceil((retryAt - nowMs) / 1_000));
}

/** Every transient 429 emitted by the presence/control-plane service carries
 * one machine-readable deadline so automatic clients cannot invent a faster
 * retry cadence. */
export function rateLimitedJson(
  body: unknown,
  retryAfterSeconds = DEFAULT_RETRY_AFTER_SECONDS,
): Response {
  const bounded = Number.isSafeInteger(retryAfterSeconds) && retryAfterSeconds > 0
    ? retryAfterSeconds
    : DEFAULT_RETRY_AFTER_SECONDS;
  return new Response(JSON.stringify(body), {
    status: 429,
    headers: {
      "content-type": "application/json",
      "retry-after": String(bounded),
    },
  });
}
