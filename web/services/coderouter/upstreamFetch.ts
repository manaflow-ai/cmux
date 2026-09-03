// Upstream fetch with a bound on the time to response headers.
//
// The Codex and Claude data planes stream model output for up to the route's
// `maxDuration` (30 minutes), so the fetch itself cannot carry a plain
// timeout: aborting the signal after headers would cut the stream. What must
// never happen is a hung upstream that holds the function, and the guest's
// turn, for the full 30 minutes without ever answering. This helper aborts
// only while headers are outstanding; once they arrive the timer is cleared
// and the body streams freely. A timeout surfaces as a transport failure, so
// the proxies fail over to the next account exactly like a connection error.

export const UPSTREAM_HEADERS_TIMEOUT_ENV = "CODEROUTER_UPSTREAM_HEADERS_TIMEOUT_MS";
/** Non-streaming completions can legitimately take minutes before headers. */
export const DEFAULT_UPSTREAM_HEADERS_TIMEOUT_MS = 10 * 60_000;
const MIN_TIMEOUT_MS = 1_000;
const MAX_TIMEOUT_MS = 30 * 60_000;

export class UpstreamHeadersTimeoutError extends Error {
  readonly timeoutMs: number;

  constructor(timeoutMs: number) {
    super(`Upstream sent no response headers within ${timeoutMs} ms`);
    this.name = "UpstreamHeadersTimeoutError";
    this.timeoutMs = timeoutMs;
  }
}

export function upstreamHeadersTimeoutMs(
  env: Record<string, string | undefined> = process.env,
): number {
  const raw = env[UPSTREAM_HEADERS_TIMEOUT_ENV]?.trim();
  if (!raw || !/^\d+$/.test(raw)) return DEFAULT_UPSTREAM_HEADERS_TIMEOUT_MS;
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed)) return DEFAULT_UPSTREAM_HEADERS_TIMEOUT_MS;
  return Math.min(MAX_TIMEOUT_MS, Math.max(MIN_TIMEOUT_MS, parsed));
}

/**
 * `fetchImpl(input, init)` that rejects with `UpstreamHeadersTimeoutError`
 * when no headers arrive within `timeoutMs`. A caller-supplied `init.signal`
 * still aborts the whole request, headers and body alike.
 */
export async function fetchWithHeadersTimeout(
  fetchImpl: typeof fetch,
  input: string | URL,
  init: RequestInit,
  timeoutMs: number = upstreamHeadersTimeoutMs(),
): Promise<Response> {
  const controller = new AbortController();
  const outer = init.signal ?? null;
  const forward = () => controller.abort(outer?.reason);
  if (outer) {
    if (outer.aborted) controller.abort(outer.reason);
    else outer.addEventListener("abort", forward, { once: true });
  }
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort(new UpstreamHeadersTimeoutError(timeoutMs));
  }, timeoutMs);
  try {
    return await fetchImpl(input, { ...init, signal: controller.signal });
  } catch (error) {
    if (timedOut) throw new UpstreamHeadersTimeoutError(timeoutMs);
    throw error;
  } finally {
    clearTimeout(timer);
    outer?.removeEventListener("abort", forward);
  }
}
