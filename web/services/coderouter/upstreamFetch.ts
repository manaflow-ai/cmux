import { runWithCloudDbQuerySignal } from "../../db/queryScope";

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
/**
 * Header failover gets less than the 1,800-second route ceiling. The spare
 * five minutes lets the handler emit telemetry and a bounded error response
 * instead of being killed while it is still selecting another account.
 */
export const CODEROUTER_UPSTREAM_FAILOVER_BUDGET_MS = 25 * 60_000;
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

/** A dependency operation that outlived the request-wide failover budget. */
export class CoderouterOperationDeadlineError extends Error {
  readonly timeoutMs: number;

  constructor(timeoutMs: number) {
    super(`CodeRouter operation exceeded the ${timeoutMs} ms request budget`);
    this.name = "CoderouterOperationDeadlineError";
    this.timeoutMs = timeoutMs;
  }
}

/**
 * Bound non-fetch work, such as account selection or credential loading, to
 * the same request-wide deadline used by upstream header attempts. The
 * operation receives a composed signal so implementations can stop their own
 * I/O; the race also bounds implementations that do not yet accept a signal.
 */
export async function withCoderouterOperationDeadline<T>(
  outerSignal: AbortSignal,
  deadlineAt: number,
  now: () => number,
  operation: (signal: AbortSignal) => Promise<T>,
): Promise<T> {
  const timeoutMs = Math.ceil(deadlineAt - now());
  if (timeoutMs <= 0) throw new CoderouterOperationDeadlineError(0);

  const timeoutController = new AbortController();
  const signal = AbortSignal.any([outerSignal, timeoutController.signal]);
  let timer: ReturnType<typeof setTimeout> | undefined;
  let removeOuterAbortListener: () => void = () => undefined;
  const outerAbort = new Promise<never>((_, reject) => {
    const rejectAborted = () => {
      reject(outerSignal.reason ?? new DOMException("The operation was aborted.", "AbortError"));
    };
    if (outerSignal.aborted) {
      rejectAborted();
      return;
    }
    outerSignal.addEventListener("abort", rejectAborted, { once: true });
    removeOuterAbortListener = () => outerSignal.removeEventListener("abort", rejectAborted);
  });
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      const error = new CoderouterOperationDeadlineError(timeoutMs);
      timeoutController.abort(error);
      reject(error);
    }, timeoutMs);
  });
  return await runWithCloudDbQuerySignal(signal, async () => {
    try {
      return await Promise.race([
        Promise.resolve().then(() => operation(signal)),
        timeout,
        outerAbort,
      ]);
    } finally {
      if (timer !== undefined) clearTimeout(timer);
      removeOuterAbortListener();
    }
  });
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
 * Returns the header timeout that fits inside a request-wide failover
 * deadline. `null` means that no further upstream attempt may start.
 */
export function remainingUpstreamHeadersTimeoutMs(
  deadlineAt: number,
  now: number = performance.now(),
  configuredTimeoutMs: number = upstreamHeadersTimeoutMs(),
): number | null {
  const remaining = deadlineAt - now;
  if (remaining <= 0) return null;
  return Math.min(configuredTimeoutMs, Math.max(1, Math.ceil(remaining)));
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
  const timeoutController = new AbortController();
  const outer = init.signal;
  // The timeout controller is only for the header phase. Keep the caller's
  // signal in the composed signal so cancellation still reaches the body
  // after headers have arrived and the timer has been cleared.
  const requestSignal = outer
    ? AbortSignal.any([outer, timeoutController.signal])
    : timeoutController.signal;
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    timeoutController.abort(new UpstreamHeadersTimeoutError(timeoutMs));
  }, timeoutMs);
  try {
    return await fetchImpl(input, { ...init, signal: requestSignal });
  } catch (error) {
    if (timedOut) throw new UpstreamHeadersTimeoutError(timeoutMs);
    throw error;
  } finally {
    clearTimeout(timer);
  }
}
