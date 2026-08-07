// Shared HTTP lifecycle for the newsletter source adapters (Stack, Stripe):
// per-request abort deadline, bounded retries with backoff for transient
// failures (429 and 5xx), and fail-fast on permanent 4xx errors. Living in
// one place keeps timeout/retry/error behavior from drifting between the
// two paginated sources.

import type { FetchLike } from "./resend-client";

const REQUEST_TIMEOUT_MS = 30_000;
const MAX_ATTEMPTS = 3;
const BACKOFF_BASE_MS = 1_000;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function fetchSourceJson<T>(options: {
  fetchImpl: FetchLike;
  url: string;
  headers?: Record<string, string>;
  // Human-readable operation name used in every error message; must not
  // contain request data.
  label: string;
  timeoutMs?: number;
}): Promise<T> {
  const timeoutMs = options.timeoutMs ?? REQUEST_TIMEOUT_MS;
  for (let attempt = 1; ; attempt += 1) {
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), timeoutMs);
    let status: number | null = null;
    let text: string | null = null;
    let transientFailure: string | null = null;
    try {
      const response = await options.fetchImpl(options.url, {
        method: "GET",
        headers: options.headers,
        signal: abort.signal,
      });
      status = response.status;
      text = await response.text();
    } catch (cause) {
      // Timeouts and transport failures (DNS, TLS, connection reset) are
      // all transient from the caller's perspective; both go through the
      // same bounded retry path instead of aborting the reconciliation.
      transientFailure = abort.signal.aborted
        ? `${options.label} timed out after ${timeoutMs}ms`
        : `${options.label} network error: ${String(cause).slice(0, 200)}`;
    } finally {
      clearTimeout(timer);
    }

    if (status !== null && text !== null) {
      if (status < 400) {
        return JSON.parse(text) as T;
      }
      // 429 and 5xx are transient; other 4xx are permanent (bad key, bad
      // request) and retrying would only delay the real error.
      if (status !== 429 && status < 500) {
        throw new Error(
          `${options.label} failed with ${status}: ${text.slice(0, 200)}`,
        );
      }
      transientFailure = `${options.label} failed with ${status}: ${text.slice(0, 200)}`;
    }

    if (attempt >= MAX_ATTEMPTS) {
      throw new Error(transientFailure ?? `${options.label} failed`);
    }
    await sleep(BACKOFF_BASE_MS * attempt);
  }
}
