/**
 * Make a Stack Auth 429 final for the SDK call that received it.
 *
 * The Stack SDK answers a 429 by sleeping for its Retry-After and then walking
 * every API host twice (api, api1, api2: six calls, six waits), or retrying
 * five times with backoff when only one host is configured. Stack throttles per
 * project, so every one of those calls is throttled too, and each one holds a
 * request that its caller has already given up on (the SDK takes no
 * AbortSignal). Our own code already treats a throttle as a retryable answer
 * (`authProviderErrorResponse` sends 429 with Retry-After, the native path
 * opens a short circuit), so the SDK's in-request retry only adds load.
 *
 * The guard wraps `fetch` for requests the SDK sends for this project: they
 * carry its project-id header and the SDK's per-request random nonce, so every
 * Stack host the SDK may fail over to is covered. Our own Stack REST helpers
 * (the webhook mirror reads, contact channels, user PATCH) send no nonce and
 * keep handling a 429 response themselves. A 429 becomes a thrown error whose cause is the 429
 * response. The SDK reads a thrown non-network error with a 4xx Stack response
 * in its cause as an application answer: it neither waits nor tries another
 * host, and the error reaches our code with the 429 status in its cause chain,
 * where `hasAuthRateLimitSignal` recognizes it.
 */
const GUARD_MARK = Symbol.for("cmux.stackThrottleFetchGuard");
const PROJECT_HEADERS = ["x-hexclave-project-id", "x-stack-project-id"] as const;
const SDK_NONCE_HEADER = "x-hexclave-random-nonce";

export class StackRateLimitedResponseError extends Error {
  readonly status = 429;

  constructor(readonly response: Response) {
    super("Stack Auth rate limited", { cause: response });
    this.name = "StackRateLimitedResponseError";
  }
}

type GuardedFetch = typeof fetch & { [GUARD_MARK]?: true };

type GuardTarget = typeof globalThis & { [GUARD_MARK]?: true };

/**
 * Whether the guard is in this process's fetch chain. Recorded on the global
 * rather than read off `fetch`, because OpenTelemetry and Next.js wrap fetch
 * again after instrumentation registers.
 */
export function isStackThrottleFetchGuardInstalled(target: typeof globalThis): boolean {
  return (target as GuardTarget)[GUARD_MARK] === true;
}

/** Test hook: forget the install so a test can restore and re-wrap fetch. */
export function resetStackThrottleFetchGuardForTests(target: typeof globalThis): void {
  delete (target as GuardTarget)[GUARD_MARK];
}

/** Install once per process; later calls (and hot reloads) are no-ops. */
export function installStackThrottleFetchGuard(target: typeof globalThis, projectId: string): void {
  const current = target.fetch as GuardedFetch;
  if (!projectId || current[GUARD_MARK] || isStackThrottleFetchGuardInstalled(target)) return;
  const base = current;
  const guarded = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const response = await base(input, init);
    if (response.status !== 429 || !isStackProjectRequest(input, init, projectId)) return response;
    // The guard owns the body now; the caller never sees it.
    void response.body?.cancel().catch(() => {});
    throw new StackRateLimitedResponseError(sdkFinalThrottleResponse(response));
  }) as GuardedFetch;
  guarded[GUARD_MARK] = true;
  target.fetch = guarded;
  (target as GuardTarget)[GUARD_MARK] = true;
}

/**
 * A bodiless copy of the 429. The SDK treats a 4xx in the cause as final only
 * when the response carries a Stack request-id or known-error header (that is
 * how it tells Stack's own answer from a proxy's). Stack sets the request id
 * on its responses; when an edge answered without it, the guard marks the copy
 * so the SDK does not fail over to another host that is throttled the same way.
 */
function sdkFinalThrottleResponse(response: Response): Response {
  const headers = new Headers(response.headers);
  if (!headers.has("x-hexclave-request-id") && !headers.has("x-stack-request-id")) {
    headers.set("x-hexclave-request-id", "cmux-throttle-guard");
  }
  return new Response(null, { status: 429, headers });
}

function isStackProjectRequest(input: RequestInfo | URL, init: RequestInit | undefined, projectId: string): boolean {
  const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined));
  return headers.has(SDK_NONCE_HEADER) && PROJECT_HEADERS.some((name) => headers.get(name) === projectId);
}
