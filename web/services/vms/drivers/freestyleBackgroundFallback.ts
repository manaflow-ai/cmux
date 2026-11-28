/**
 * The freestyle SDK asks for background mode on every API-key request
 * (`x-freestyle-background-after-secs`). While the provider's background store
 * is down it answers 503 BACKGROUND_STORE_UNAVAILABLE to all of them, even
 * though the same request without the header succeeds, and the SDK has no
 * fallback (https://github.com/manaflow-ai/cmux/issues/26414). The provider
 * refuses the request before running it, so this boundary sends it once more
 * without the header, and keeps sending plain requests for a cool-down so
 * every call does not pay a doomed round trip first. A plain request runs
 * inline under the caller's own timeout instead of answering 202.
 */
export const FREESTYLE_BACKGROUND_HEADER = "x-freestyle-background-after-secs";
export const FREESTYLE_BACKGROUND_STORE_UNAVAILABLE = "BACKGROUND_STORE_UNAVAILABLE";
const DEFAULT_COOL_DOWN_MS = 60_000;

export type FreestyleBackgroundFallbackState = { plainUntil: number };

type Options = {
  readonly fetch: typeof fetch;
  /** Shared by every client of the account, so one 503 switches them all. */
  readonly state?: FreestyleBackgroundFallbackState;
  readonly coolDownMs?: number;
  readonly now?: () => number;
};

const sharedState: FreestyleBackgroundFallbackState = { plainUntil: 0 };

export function freestyleBackgroundFallbackFetch(options: Options): typeof fetch {
  const state = options.state ?? sharedState;
  const coolDownMs = options.coolDownMs ?? DEFAULT_COOL_DOWN_MS;
  const now = options.now ?? Date.now;
  return (async (input, init) => {
    // The SDK passes a URL string and a replayable body; anything else is sent as given.
    if (input instanceof Request || !init || !replayableBody(init.body)) return options.fetch(input, init);
    const headers = new Headers(init.headers);
    if (!headers.has(FREESTYLE_BACKGROUND_HEADER)) return options.fetch(input, init);
    const plain = () => {
      headers.delete(FREESTYLE_BACKGROUND_HEADER);
      return options.fetch(input, { ...init, headers });
    };
    if (now() < state.plainUntil) return plain();
    const response = await options.fetch(input, init);
    if (!(await isBackgroundStoreUnavailable(response))) return response;
    state.plainUntil = now() + coolDownMs;
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
    return body?.code === FREESTYLE_BACKGROUND_STORE_UNAVAILABLE;
  } catch {
    return false;
  }
}
