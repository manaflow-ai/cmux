export type FreestylePreconnectOptions = {
  readonly baseUrl?: string;
  readonly fetch?: typeof fetch;
  readonly timeoutMs?: number;
  readonly now?: () => number;
};

type FreestyleWarmupState = { promise?: Promise<void>; succeeded?: boolean; succeededAtMs?: number };

const freestyleWarmupStates = new WeakMap<object, Map<string, FreestyleWarmupState>>();
// Undici's default global-fetch idle pool expires around four seconds. Keep a
// successful probe for less than that, so an idle Cloud path probes again
// before the next provider call rather than trusting a closed socket.
const FREESTYLE_WARMUP_REUSE_MS = 3_000;

function warmupStateFor(fetchImpl: typeof fetch, baseUrl: string): FreestyleWarmupState {
  const key = fetchImpl as unknown as object;
  const states = freestyleWarmupStates.get(key) ?? new Map<string, FreestyleWarmupState>();
  const existing = states.get(baseUrl);
  if (existing) return existing;
  const state: FreestyleWarmupState = {};
  states.set(baseUrl, state);
  freestyleWarmupStates.set(key, states);
  return state;
}

async function warmFreestyleConnection(options: Required<Omit<FreestylePreconnectOptions, "now">>): Promise<void> {
  await options.fetch(`${options.baseUrl}/`, {
    method: "HEAD",
    signal: AbortSignal.timeout(options.timeoutMs),
  });
}

/** Opens the provider connection pool with single-flight, bounded best effort. */
export function preconnectFreestyle(options: FreestylePreconnectOptions = {}): Promise<void> {
  const baseUrl = options.baseUrl?.trim() || process.env.FREESTYLE_API_URL?.trim() || "https://api.freestyle.sh";
  const fetchImpl = options.fetch ?? fetch;
  const timeoutMs = options.timeoutMs ?? 3_000;
  const now = options.now ?? Date.now;
  const state = warmupStateFor(fetchImpl, baseUrl);
  const warmupAgeMs = state.succeededAtMs === undefined ? undefined : Math.max(0, now() - state.succeededAtMs);
  if (state.succeeded && warmupAgeMs !== undefined && warmupAgeMs < FREESTYLE_WARMUP_REUSE_MS) {
    return Promise.resolve();
  }
  state.succeeded = undefined;
  if (state.promise) return state.promise;
  const promise = warmFreestyleConnection({ baseUrl, fetch: fetchImpl, timeoutMs })
    .then(() => { state.succeeded = true; state.succeededAtMs = now(); })
    .catch(() => { state.succeeded = false; state.succeededAtMs = undefined; });
  const settled = promise.finally(() => {
    if (state.promise === settled) state.promise = undefined;
  });
  state.promise = settled;
  return settled;
}
