import { setTimeout as delay } from "node:timers/promises";

/** Maximum time the canary waits for a create continuation to become visible. */
export const CREATE_VM_RETRY_BUDGET_MS = 8 * 60 * 1_000;

/**
 * Build the authenticated VM create request used by the smoke runner.
 *
 * Keeping request construction here lets the retry loop exercise the exact
 * same idempotency key and payload on every attempt.
 */
export function createVmRequest({ targetUrl, authHeaders, provider, image, fetchWithTimeout }) {
  const body = {
    ...(provider === "default" ? {} : { provider }),
    ...(image ? { image } : {}),
  };
  return async (idempotencyKey, signal) => {
    const response = await fetchWithTimeout(`${targetUrl}/api/vm`, {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json", "idempotency-key": idempotencyKey },
      body: JSON.stringify(body),
    }, undefined, signal);
    const text = await response.text();
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = null;
    }
    return { status: response.status, body: parsed, text };
  };
}

/**
 * Retry a create after the route reports that the idempotent operation is
 * still running. Every retry receives the original key, so it can only return
 * the existing row or observe that the same row is still provisioning.
 */
export async function createVmWithRetry({
  idempotencyKey,
  send,
  sleep = (ms, signal) => delay(ms, undefined, { signal }),
  signal = /** @type {AbortSignal | undefined} */ (undefined),
  now = Date.now,
  budgetMs = CREATE_VM_RETRY_BUDGET_MS,
}) {
  const startedAt = now();
  for (;;) {
    throwIfAborted(signal);
    const response = await send(idempotencyKey, signal);
    throwIfAborted(signal);
    if (response.status === 200) {
      if (!response.body || typeof response.body !== "object" || !response.body.id) {
        throw new Error("POST /api/vm response missing id");
      }
      return response.body;
    }

    if (!isCreateInProgressResponse(response.status, response.body)) {
      throw new Error(`POST /api/vm expected 200, got ${response.status}: ${response.text ?? formatBody(response.body)}`);
    }

    const remainingMs = budgetMs - Math.max(0, now() - startedAt);
    if (remainingMs <= 0) {
      throw new Error(`POST /api/vm remained in progress for ${budgetMs} ms`);
    }
    await sleep(Math.min(remainingMs, retryAfterMsFrom(response.body)), signal);
    throwIfAborted(signal);
    if (Math.max(0, now() - startedAt) >= budgetMs) {
      throw new Error(`POST /api/vm remained in progress for ${budgetMs} ms`);
    }
  }
}

/** Identify only the two create states that are safe to poll with one key. */
function isCreateInProgressResponse(status, body) {
  if (!body || typeof body !== "object") return false;
  if (status === 503) {
    return body.error === "vm_operation_in_progress" && body.phase === "create" && body.retryable === true;
  }
  return status === 409 && body.error === "vm_create_in_progress";
}

/** Convert the API retry hint to milliseconds, using the create default. */
function retryAfterMsFrom(body) {
  const seconds = body && typeof body === "object" && Number(body.retryAfterSeconds);
  return Number.isFinite(seconds) && seconds > 0 ? Math.ceil(seconds * 1_000) : 15_000;
}

/** Stop before another request when the caller has been cancelled. */
function throwIfAborted(signal) {
  if (!signal?.aborted) return;
  throw signal.reason instanceof Error ? signal.reason : new Error("Cloud VM create retry aborted");
}

/** Render an unexpected response body without allowing formatting to fail. */
function formatBody(body) {
  try {
    return JSON.stringify(body);
  } catch {
    return String(body);
  }
}
