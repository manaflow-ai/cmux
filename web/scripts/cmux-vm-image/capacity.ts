/**
 * The VM provider's "server is at capacity; try again shortly" answer, retried for every call the image
 * scripts make (create, exec, file write, snapshot, delete) at the one seam they share: the client's fetch.
 *
 * On 2026-11-16 the image roll failed four runs on it: a file write in the bake (jobs 133444252629,
 * 133446604123), the VM delete after a passing smoke (133426693737) and the agent-tools probe (133432870475).
 * The answer is HTTP 429, code TOO_MANY_REQUESTS: the provider refused the request before doing it, so
 * sending it again is safe whatever its method. Nothing else is retried here: any other status, a lost
 * response, and a stored answer of a request that ran (the background request id header) go to the caller
 * as before. The wait is bounded (CAPACITY_RETRY_DELAYS_MS, about 3 minutes), so a real outage still fails.
 */

/** Waits before each retry; Retry-After lengthens one up to CAPACITY_RETRY_MAX_DELAY_MS. 7 tries over 195 s. */
export const CAPACITY_RETRY_DELAYS_MS: readonly number[] = [5_000, 10_000, 20_000, 40_000, 60_000, 60_000];
export const CAPACITY_RETRY_MAX_DELAY_MS = 60_000;
/** The client's own header on a background request's stored answer: that request ran. */
const BACKGROUND_REQUEST_ID_HEADER = "x-freestyle-background-request-id";

type Fetch = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

export type CapacityRetryDeps = {
  sleep?: (ms: number, signal?: AbortSignal | null) => Promise<void>;
  log?: (line: string) => void;
  delaysMs?: readonly number[];
};

/** A 429 whose message says the provider is at capacity. */
export function isCapacityAnswer(status: number, body: string): boolean {
  if (status !== 429) return false;
  let message = body;
  try {
    const parsed = JSON.parse(body) as { message?: unknown };
    if (typeof parsed?.message === "string") message = parsed.message;
  } catch {
    // a plain-text body is its own message
  }
  return /\bat capacity\b/i.test(message);
}

/** Only a body sent whole can be sent again; a stream is spent by the first send. */
function replayable(body: RequestInit["body"] | undefined): boolean {
  return body == null || typeof body === "string" || body instanceof Uint8Array || body instanceof ArrayBuffer || body instanceof Blob || body instanceof URLSearchParams;
}

function retryAfterMs(response: Response): number {
  const seconds = Number(response.headers.get("retry-after"));
  return Number.isFinite(seconds) && seconds > 0 ? seconds * 1_000 : 0;
}

const defaultSleep = (ms: number, signal?: AbortSignal | null) =>
  new Promise<void>((resolve, reject) => {
    if (signal?.aborted) return reject(signal.reason);
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(signal?.reason);
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });

const describe = (input: string | URL | Request, init?: RequestInit) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  return `${(init?.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase()} ${url.replace(/^https?:\/\/[^/]+/, "")}`;
};

/** `inner` with a capacity answer retried after each of `delaysMs`; the last answer goes to the caller as is. */
export function capacityRetryFetch(inner: Fetch, deps: CapacityRetryDeps = {}): Fetch {
  const sleep = deps.sleep ?? defaultSleep;
  const log = deps.log ?? ((line: string) => console.error(line));
  const delays = deps.delaysMs ?? CAPACITY_RETRY_DELAYS_MS;
  return async (input, init) => {
    const canRetry = !(input instanceof Request) && replayable(init?.body) && !describe(input, init).includes("/background-requests/");
    for (let attempt = 0; ; attempt++) {
      const response = await inner(input, init);
      if (!canRetry || attempt >= delays.length || response.status !== 429 || response.headers.has(BACKGROUND_REQUEST_ID_HEADER)) return response;
      const body = await response.clone().text().catch(() => "");
      if (!isCapacityAnswer(response.status, body)) return response;
      const wait = Math.min(Math.max(delays[attempt], retryAfterMs(response)), CAPACITY_RETRY_MAX_DELAY_MS);
      log(`PROVIDER AT CAPACITY: ${describe(input, init)} answered 429; retry ${attempt + 1}/${delays.length} in ${(wait / 1000).toFixed(0)}s`);
      await response.body?.cancel().catch(() => {});
      await sleep(wait, init?.signal);
    }
  };
}

/**
 * Puts the retry under a constructed client's transport, keeping the transport the client chose (its HTTP/2
 * dispatcher). The SDK keeps it as `client.fetchImpl`; a reshaped SDK fails here, loudly, not silently unretried.
 */
export function installCapacityRetry<T extends object>(freestyle: T, deps: CapacityRetryDeps = {}): T {
  const client = (freestyle as unknown as { client?: { fetchImpl?: unknown } }).client;
  if (!client || typeof client.fetchImpl !== "function") throw new Error("freestyle client has no fetchImpl: the capacity retry needs updating for this SDK");
  const inner = client.fetchImpl as Fetch;
  client.fetchImpl = capacityRetryFetch((input, init) => inner.call(client, input, init), deps);
  return freestyle;
}
