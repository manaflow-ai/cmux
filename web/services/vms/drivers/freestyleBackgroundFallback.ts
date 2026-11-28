/**
 * The freestyle SDK asks for background mode (`x-freestyle-background-after-secs`)
 * on API-key requests. While the provider's background store is down it answers
 * 503 BACKGROUND_STORE_UNAVAILABLE to every one of them, although the same
 * request without the header succeeds, and the SDK has no fallback
 * (https://github.com/manaflow-ai/cmux/issues/26414).
 *
 * The provider refuses such a request before running it, so replaying it once
 * without the header is safe even for create or exec. No other 503 is replayed:
 * it may have run. After a refusal this process sends plain requests for a
 * cool-down so each call does not pay a doomed round trip first. A plain
 * request runs inline under its own timeout instead of answering 202.
 */
const BACKGROUND_HEADER = "x-freestyle-background-after-secs";
const COOL_DOWN_MS = 60_000;

/** Process-wide: one refusal switches every cached client of the account. */
const state = { plainUntil: 0 };

export function freestyleBackgroundFallbackFetch(fetchImpl: typeof fetch): typeof fetch {
  return (async (input, init) => {
    // The SDK passes a URL string and a string or byte body; anything else is sent as given.
    if (input instanceof Request || !init || !replayableBody(init.body)) return fetchImpl(input, init);
    const headers = new Headers(init.headers);
    if (!headers.has(BACKGROUND_HEADER)) return fetchImpl(input, init);
    const plain = () => {
      headers.delete(BACKGROUND_HEADER);
      return fetchImpl(input, { ...init, headers });
    };
    if (Date.now() < state.plainUntil) return plain();
    const response = await fetchImpl(input, init);
    if (!(await isBackgroundStoreUnavailable(response))) return response;
    state.plainUntil = Date.now() + COOL_DOWN_MS;
    await response.body?.cancel().catch(() => {});
    return plain();
  }) as typeof fetch;
}

function replayableBody(body: BodyInit | null | undefined): boolean {
  return body == null || typeof body === "string" || body instanceof ArrayBuffer || ArrayBuffer.isView(body)
    || body instanceof Blob || body instanceof URLSearchParams;
}

async function isBackgroundStoreUnavailable(response: Response): Promise<boolean> {
  if (response.status !== 503) return false;
  try {
    const body = await response.clone().json() as { code?: unknown } | null;
    return body?.code === "BACKGROUND_STORE_UNAVAILABLE";
  } catch {
    return false;
  }
}
