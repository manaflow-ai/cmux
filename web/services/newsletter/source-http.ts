// Shared HTTP lifecycle for the newsletter source adapters (Stack, Stripe):
// per-request abort deadline, bounded retries with backoff for transient
// failures (429, 5xx, and transport errors), and fail-fast on permanent 4xx
// errors. Keeping this behavior in one place prevents the two paginated
// sources from drifting apart.

import type { FetchLike } from "./resend-client";

const REQUEST_TIMEOUT_MS = 30_000;
const MAX_ATTEMPTS = 3;
const BACKOFF_BASE_MS = 1_000;
const MAX_RETRY_AFTER_MS = 30_000;

function sleep(ms: number, signal: AbortSignal | undefined, label: string) {
  return new Promise<void>((resolve, reject) => {
    if (signal?.aborted) {
      reject(new Error(`${label} cancelled`));
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      if (timer) clearTimeout(timer);
      reject(new Error(`${label} cancelled`));
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

function retryAfterMs(
  value: string | null,
  nowMs: number,
  fallbackMs: number,
  maxMs: number,
): number {
  if (!value) return Math.min(fallbackMs, maxMs);
  const seconds = Number(value.trim());
  if (Number.isFinite(seconds) && seconds >= 0) {
    return Math.min(seconds * 1_000, maxMs);
  }
  const dateMs = Date.parse(value);
  if (Number.isFinite(dateMs)) {
    return Math.min(Math.max(0, dateMs - nowMs), maxMs);
  }
  return Math.min(fallbackMs, maxMs);
}

export async function fetchSourceJson<T>(options: {
  fetchImpl: FetchLike;
  url: string;
  headers?: Record<string, string>;
  // Human-readable operation name used in every error message; it must not
  // contain request data such as an email address or secret.
  label: string;
  timeoutMs?: number;
  signal?: AbortSignal;
  // Injectable only for deterministic tests; production keeps the bounded
  // defaults below.
  maxAttempts?: number;
  backoffBaseMs?: number;
  maxRetryAfterMs?: number;
}): Promise<T> {
  const timeoutMs = options.timeoutMs ?? REQUEST_TIMEOUT_MS;
  const maxAttempts = options.maxAttempts ?? MAX_ATTEMPTS;
  const backoffBaseMs = options.backoffBaseMs ?? BACKOFF_BASE_MS;
  const maxRetryAfterMs = options.maxRetryAfterMs ?? MAX_RETRY_AFTER_MS;

  for (let attempt = 1; ; attempt += 1) {
    if (options.signal?.aborted) {
      throw new Error(`${options.label} cancelled`);
    }
    const abort = new AbortController();
    const onCallerAbort = () => abort.abort();
    options.signal?.addEventListener("abort", onCallerAbort, { once: true });
    const timer = setTimeout(() => abort.abort(), timeoutMs);
    let status: number | null = null;
    let text: string | null = null;
    let retryAfter: string | null = null;
    let transientFailure: string | null = null;
    try {
      const response = await options.fetchImpl(options.url, {
        method: "GET",
        headers: options.headers,
        signal: abort.signal,
      });
      status = response.status;
      retryAfter = response.headers.get("retry-after");
      text = await response.text();
    } catch {
      if (options.signal?.aborted) {
        throw new Error(`${options.label} cancelled`);
      }
      transientFailure = abort.signal.aborted
        ? `${options.label} timed out after ${timeoutMs}ms`
        : `${options.label} network failure`;
    } finally {
      clearTimeout(timer);
      options.signal?.removeEventListener("abort", onCallerAbort);
    }

    if (status !== null && text !== null) {
      if (status < 400) {
        try {
          return JSON.parse(text) as T;
        } catch {
          throw new Error(`${options.label} returned invalid JSON`);
        }
      }
      // 429 and 5xx are transient; other 4xx are permanent (bad key, bad
      // request) and retrying would only delay the real error. Never include
      // the upstream body: provider payloads can echo request data.
      if (status !== 429 && status < 500) {
        throw new Error(`${options.label} failed with HTTP ${status}`);
      }
      transientFailure = `${options.label} failed with HTTP ${status}`;
    }

    if (attempt >= maxAttempts) {
      throw new Error(transientFailure ?? `${options.label} failed`);
    }

    const fallbackMs = backoffBaseMs * attempt;
    const delayMs =
      status === 429
        ? retryAfterMs(retryAfter, Date.now(), fallbackMs, maxRetryAfterMs)
        : Math.min(fallbackMs, maxRetryAfterMs);
    await sleep(delayMs, options.signal, options.label);
  }
}
