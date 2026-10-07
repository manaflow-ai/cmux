/**
 * The upstream VM provider, as this service sees it.
 *
 * Every method demands gdp-ts proofs about its exact named arguments, and the
 * upstream id comes only from a minted TenantOwnsResource proof. The raw HTTP request
 * function and the provider key are private to `makeUpstreamClient`; nothing
 * else in the Worker can reach the provider. See upstream/PINNED.json for the
 * pinned provider API surface.
 */
import type { Named } from "@gdp-ts/core";
import { Context, Data, Effect, Redacted, Schema } from "effect";
import type { VmId } from "../lib/ids.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { upstreamIdOf, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";

export class UpstreamError extends Data.TaggedError("UpstreamError")<{
  readonly operation: string;
  /** HTTP status from the provider, or null when no response arrived. */
  readonly status: number | null;
}> {}

/** The fields of the provider's VM record this service reads. Everything else is ignored. */
export const UpstreamVm = Schema.Struct({
  state: Schema.String,
  resources: Schema.Struct({ cpu: Schema.Number, memory: Schema.Number, storage: Schema.Number }),
  idleTimeoutSeconds: Schema.optional(Schema.NullOr(Schema.Number)),
  createdAt: Schema.String,
  updatedAt: Schema.String,
});
export type UpstreamVm = typeof UpstreamVm.Type;

export interface UpstreamClientService {
  readonly getVm: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: TenantOwnsResource<C, R>; readonly scope: KeyHasScope<C, "vm:read"> },
  ) => Effect.Effect<UpstreamVm, UpstreamError>;
}

export class UpstreamClient extends Context.Tag("cmux-vm/UpstreamClient")<UpstreamClient, UpstreamClientService>() {}

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
