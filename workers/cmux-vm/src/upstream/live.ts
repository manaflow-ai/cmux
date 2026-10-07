/**
 * The upstream client implementation: the only module that sends the provider
 * key. Every method demands gdp-ts proofs about its exact named arguments, and
 * the upstream id comes only from a minted TenantOwnsResource proof. Lint
 * (oxlint.config.ts, no-restricted-imports) lets only src/upstream/,
 * src/proofs/ and the composition root src/index.ts import this module.
 */
import { Effect, Layer, Redacted, Schema } from "effect";
import { upstreamIdOf } from "../proofs/tenant-owns-resource.ts";
import { UpstreamClient, UpstreamError, UpstreamVm, type UpstreamClientService } from "./client.ts";

export interface UpstreamConfig {
  readonly baseUrl: string;
  readonly apiKey: Redacted.Redacted<string>;
  readonly fetch?: (request: Request) => Promise<Response>;
  readonly timeoutMs?: number;
}

const MAX_RESPONSE_BYTES = 1024 * 1024;

export function makeUpstreamClient(config: UpstreamConfig): UpstreamClientService {
  const base = new URL(config.baseUrl);
  if (base.protocol !== "https:" || base.username || base.password || base.search || base.hash || base.pathname !== "/") {
    throw new Error("upstream base URL must be a bare HTTPS origin");
  }
  const send = config.fetch ?? ((request: Request) => fetch(request));
  const timeoutMs = config.timeoutMs ?? 10_000;

  const getJson = (operation: string, path: string): Effect.Effect<unknown, UpstreamError> =>
    Effect.tryPromise({
      try: async () => {
        const request = new Request(new URL(path, base), {
          method: "GET",
          headers: { authorization: `Bearer ${Redacted.value(config.apiKey)}`, accept: "application/json" },
          redirect: "manual",
          signal: AbortSignal.timeout(timeoutMs),
        });
        const response = await send(request);
        if (!response.ok) {
          await response.body?.cancel();
          return { ok: false as const, status: response.status };
        }
        const bytes = new Uint8Array(await response.arrayBuffer());
        if (bytes.byteLength > MAX_RESPONSE_BYTES) return { ok: false as const, status: response.status };
        const body: unknown = JSON.parse(new TextDecoder().decode(bytes));
        return { ok: true as const, body };
      },
      catch: () => new UpstreamError({ operation, status: null }),
    }).pipe(
      Effect.flatMap((result) =>
        result.ok ? Effect.succeed(result.body) : Effect.fail(new UpstreamError({ operation, status: result.status })),
      ),
    );

  return {
    getVm: (_vm, { owns }) =>
      Effect.try(() => upstreamIdOf(owns)).pipe(
        Effect.orDie,
        Effect.flatMap((upstreamId) => getJson("getVm", `/v5/vms/${encodeURIComponent(upstreamId)}`)),
      ).pipe(
        Effect.flatMap(Schema.decodeUnknown(UpstreamVm)),
        Effect.mapError((error) => (error instanceof UpstreamError ? error : new UpstreamError({ operation: "getVm", status: null }))),
      ),
  };
}

/**
 * The live client from Worker configuration. The key is wrapped in Redacted at
 * once. Built eagerly, so a bad base URL throws here (src/index.ts answers 503).
 */
export const upstreamLayer = (config: { readonly baseUrl: string; readonly apiKey: string }): Layer.Layer<UpstreamClient> =>
  Layer.succeed(UpstreamClient, makeUpstreamClient({ baseUrl: config.baseUrl, apiKey: Redacted.make(config.apiKey) }));
