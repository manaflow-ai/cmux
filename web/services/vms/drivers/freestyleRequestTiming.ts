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
  readonly signal?: AbortSignal;
  readonly fetch?: typeof fetch;
  readonly record?: (event: FreestyleRequestTiming) => void;
  readonly now?: () => number;
};

/** The SDK's Promise-based fetch boundary; provider workflows remain Effect-owned. */
export function freestyleRequestFetch(options: Options): typeof fetch {
  const fetchImpl = options.fetch ?? fetch;
  const timeoutSignal = () => AbortSignal.timeout(options.timeoutMs);
  const request = ((input, init) => fetchImpl(input, {
    ...(init ?? {}), signal: AbortSignal.any([
      timeoutSignal(),
      ...[options.signal, init?.signal ?? (input instanceof Request ? input.signal : undefined)]
        .filter((signal): signal is AbortSignal => !!signal),
    ]),
  })) as typeof fetch;
  if (!options.record) return request;

  const clientId = randomUUID();
  const now = options.now ?? (() => performance.now());
  const record = (event: FreestyleRequestTiming) => {
    // Diagnostic output must not change request success, failure, or recovery.
    try { options.record?.(event); } catch { /* Keep the original request outcome. */ }
  };
  return (async (input, init) => {
    const rawMethod = init?.method ?? (input instanceof Request ? input.method : "GET");
    const method = /^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)$/i.test(rawMethod) ? rawMethod.toUpperCase() : "OTHER";
    const phase = requestPhase(input, method);
    const requestId = randomUUID();
    const started = now();
    const base = { clientId, requestId, phase, method };
    record({ ...base, at: new Date().toISOString(), stage: "begin" });
    try {
      const response = await request(input, init);
      record({ ...base, at: new Date().toISOString(), stage: "response", status: response.status, elapsedMs: now() - started });
      return response;
    } catch (error) {
      const errorKind = error instanceof Error && error.name === "TimeoutError" ? "timeout"
        : error instanceof Error && error.name === "AbortError" ? "cancelled" : "network";
      record({ ...base, at: new Date().toISOString(), stage: "error", errorKind, elapsedMs: now() - started });
      throw error;
    }
  }) as typeof fetch;
}

/** Only fixed route categories leave this boundary; never URLs, ids, headers, or bodies. */
function requestPhase(input: RequestInfo | URL, method: string): FreestyleRequestTiming["phase"] {
  let pathname: string;
  try { pathname = new URL(input instanceof Request ? input.url : input.toString()).pathname; }
  catch { return "provider"; }
  if (pathname === "/v5/tunnels" && method === "POST") return "tunnel_create";
  if (/^\/v5\/background-requests\/[^/]+$/.test(pathname)) return "background_result";
  if (/^\/v5\/tunnels\/[^/]+$/.test(pathname) && method === "GET") return "tunnel_read";
  if (/^\/v5\/tunnels\/[^/]+\/vpcs\/[^/]+$/.test(pathname) && method === "POST") return "tunnel_attach";
  return "provider";
}
import { randomUUID } from "node:crypto";
