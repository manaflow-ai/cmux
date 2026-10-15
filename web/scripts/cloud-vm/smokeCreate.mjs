/**
 * Retry the create request after the route has answered that the idempotent
 * create is still running. A retry always receives the original key, so the
 * API either returns the row that the background continuation completed or
 * reports that the same row is still provisioning; it cannot start a second
 * provider create.
 */
export async function createVmWithRetry({
  idempotencyKey,
  send,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  now = Date.now,
  budgetMs = 8 * 60 * 1_000,
}) {
  const startedAt = now();
  for (;;) {
    const response = await send(idempotencyKey);
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
    const retryAfterMs = retryAfterMsFrom(response.body);
    await sleep(Math.min(remainingMs, retryAfterMs));
    if (Math.max(0, now() - startedAt) >= budgetMs) {
      throw new Error(`POST /api/vm remained in progress for ${budgetMs} ms`);
    }
  }
}

function isCreateInProgressResponse(status, body) {
  if (!body || typeof body !== "object") return false;
  if (status === 503) {
    return body.error === "vm_operation_in_progress" && body.phase === "create" && body.retryable === true;
  }
  return status === 409 && body.error === "vm_create_in_progress";
}

function retryAfterMsFrom(body) {
  const seconds = body && typeof body === "object" && Number(body.retryAfterSeconds);
  return Number.isFinite(seconds) && seconds > 0 ? Math.ceil(seconds * 1_000) : 15_000;
}

function formatBody(body) {
  try {
    return JSON.stringify(body);
  } catch {
    return String(body);
  }
}
