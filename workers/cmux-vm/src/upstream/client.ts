/**
 * The upstream VM provider, as handlers see it: the service tag, its
 * proof-demanding interface and the provider's VM shape. The implementation
 * that holds the provider key is src/upstream/live.ts, which lint lets only
 * src/upstream/, src/proofs/ and the composition root (src/index.ts) import.
 * See upstream/PINNED.json for the pinned provider API surface.
 */
import type { Named } from "@gdp-ts/core";
import { Context, Data, Effect, Schema } from "effect";
import type { VmId } from "../lib/ids.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import type { TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";

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
