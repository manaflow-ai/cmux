export type FreestyleRequestTiming = {
  readonly clientId: string;
  readonly requestId: string;
  readonly at: string;
  readonly stage: "begin" | "response" | "error";
  readonly phase: "tunnel_create" | "tunnel_read" | "tunnel_attach" | "background_result" | "provider";
  readonly method: string;
  readonly elapsedMs?: number;
  readonly status?: number;
  readonly errorKind?: "timeout" | "cancelled" | "network";
};

type Options = {
  readonly timeoutMs: number;
  readonly fetch?: typeof fetch;
  readonly record?: (event: FreestyleRequestTiming) => void;
  readonly now?: () => number;
};

/** The SDK's Promise-based fetch boundary; provider workflows remain Effect-owned. */
export function freestyleRequestFetch(options: Options): typeof fetch {
  const fetchImpl = options.fetch ?? fetch;
  return ((input, init) => fetchImpl(input, {
    ...(init ?? {}), signal: AbortSignal.timeout(options.timeoutMs),
  })) as typeof fetch;
}
