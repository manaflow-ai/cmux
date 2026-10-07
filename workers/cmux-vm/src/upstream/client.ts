/**
 * The upstream VM provider, as handlers see it: the service tag, its
 * proof-demanding interface and the provider shapes handlers read. The
 * implementation that holds the provider key is src/upstream/live.ts, which
 * lint lets only src/upstream/, src/proofs/ and the composition root
 * (src/index.ts) import. See upstream/PINNED.json for the pinned surface.
 *
 * Every method demands gdp-ts proofs about its exact named arguments, and the
 * upstream id of an existing resource comes only from a minted
 * TenantOwnsResource proof. A create returns the new upstream id once, for the
 * ownership table, with effects bound to exactly that new resource (`discard`,
 * `grow`).
 */
import type { Named } from "@gdp-ts/core";
import { Context, Data, Effect, Schema } from "effect";
import type { Principal } from "../domain/principal.ts";
import type { SnapshotId, UpstreamId, VmId } from "../lib/ids.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import type { TenantMayCreate } from "../proofs/tenant-may-create.ts";
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
  maxRunSeconds: Schema.optional(Schema.NullOr(Schema.Number)),
  autoDeleteSeconds: Schema.optional(Schema.NullOr(Schema.Number)),
  createdAt: Schema.String,
  updatedAt: Schema.String,
});
export type UpstreamVm = typeof UpstreamVm.Type;


export interface CreatedResource {
  /** The provider id of the new resource, to record in the ownership table and nowhere else. */
  readonly upstreamId: UpstreamId;
  /** Deletes exactly this new resource; for when it cannot be recorded. Never fails. */
  readonly discard: Effect.Effect<void>;
}

export interface SizeRequest {
  readonly vcpus?: number | undefined;
  readonly memoryMib?: number | undefined;
  readonly diskMib?: number | undefined;
}

export interface CreateVmSpec {
  readonly cmuxId: VmId;
  readonly idleTimeoutSeconds: number;
  readonly maxRunSeconds?: number;
  readonly autoDeleteSeconds?: number;
  /** Without a source snapshot: the size to boot; picks the base image size. */
  readonly size?: SizeRequest;
  /** Deployment name (staging, production, ...), tagged on the upstream VM. */
  readonly environment: string;
}


export interface ExecSpec {
  readonly command: string;
  readonly env?: Readonly<Record<string, string>>;
  readonly stdinBase64?: string;
  readonly timeoutMs?: number;
  readonly linuxUser?: string;
}

export interface FileRead {
  readonly status: 200 | 206;
  readonly contentRange: string | null;
  readonly contentLength: string | null;
  readonly body: ReadableStream<Uint8Array>;
}

export interface FileEntryRecord {
  readonly name: string;
  readonly kind: string;
}

export type Owns<C, R> = TenantOwnsResource<C, R>;
type Write<C> = KeyHasScope<C, "vm:write">;

export interface UpstreamClientService {
  readonly getVm: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:read"> },
  ) => Effect.Effect<UpstreamVm, UpstreamError>;
  /** Reads a VM's state on the way to changing it. */
  readonly getVmForWrite: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C> },
  ) => Effect.Effect<UpstreamVm, UpstreamError>;
  /**
   * Boots a new VM for the caller's tenant. Its upstream name and metadata
   * carry the tenant id and the cmux id. With `source`, it boots from that
   * snapshot of the tenant's.
   */
  readonly createVm: <C, S = never>(
    caller: Named<C, Principal>,
    spec: CreateVmSpec,
    proofs: {
      readonly mayCreate: TenantMayCreate<C, "vm">;
      readonly scope: Write<C>;
      readonly source?: { readonly snapshot: Named<S, SnapshotId>; readonly owns: Owns<C, S> };
    },
  ) => Effect.Effect<
    CreatedResource & {
      readonly vm: UpstreamVm;
      /** Grows exactly this new VM to `size` on the axes where it is smaller. */
      readonly grow: (size: SizeRequest) => Effect.Effect<UpstreamVm, UpstreamError>;
    },
    UpstreamError
  >;
  readonly startVm: <C, R>(vm: Named<R, VmId>, proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C> }) => Effect.Effect<UpstreamVm, UpstreamError>;
  readonly pauseVm: <C, R>(vm: Named<R, VmId>, proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C> }) => Effect.Effect<UpstreamVm, UpstreamError>;
  /** Shuts the guest down from inside (the provider has no stop operation). */
  readonly shutdownVm: <C, R>(vm: Named<R, VmId>, proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C> }) => Effect.Effect<void, UpstreamError>;
  /** Deletes the VM; "gone" when the provider no longer had it. */
  readonly deleteVm: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C> },
  ) => Effect.Effect<"deleted" | "gone", UpstreamError>;
  /** Snapshots a VM for a fork. The snapshot's upstream name carries the tenant id and its cmux id. */
  readonly snapshotForFork: <C, R>(
    caller: Named<C, Principal>,
    vm: Named<R, VmId>,
    spec: { readonly cmuxId: SnapshotId },
    proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C>; readonly mayCreate: TenantMayCreate<C, "vm"> },
  ) => Effect.Effect<CreatedResource, UpstreamError>;
  /** Deletes a snapshot; "gone" when the provider no longer had it. */
  readonly deleteSnapshot: <C, S>(
    snapshot: Named<S, SnapshotId>,
    proofs: { readonly owns: Owns<C, S>; readonly scope: Write<C> | KeyHasScope<C, "snapshot:*"> },
  ) => Effect.Effect<"deleted" | "gone", UpstreamError>;
  /** Runs a command; the body is the public ExecResult, streamed as it arrives. */
  readonly exec: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:exec"> },
    spec: ExecSpec,
  ) => Effect.Effect<ReadableStream<Uint8Array>, UpstreamError>;
  readonly readFile: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:files"> },
    path: string,
    range: string | undefined,
  ) => Effect.Effect<FileRead, UpstreamError>;
  readonly writeFile: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:files"> },
    file: { readonly path: string; readonly mode: number | undefined; readonly body: ReadableStream<Uint8Array>; readonly length: number },
  ) => Effect.Effect<void, UpstreamError>;
  readonly listFiles: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:files"> },
    path: string,
  ) => Effect.Effect<ReadonlyArray<FileEntryRecord>, UpstreamError>;
}

export class UpstreamClient extends Context.Tag("cmux-vm/UpstreamClient")<UpstreamClient, UpstreamClientService>() {}

