import type { PendingVmCreation, CancellingVmCreation } from "../proofs/vm-creation.ts";
import type { VmCreationProbe } from "../domain/vm-creation.ts";
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
import type { VmNetworkAllowed } from "../proofs/vm-network.ts";
import type { VmImageAllowed } from "../proofs/vm-image.ts";
import type { MeshId, SnapshotId, UpstreamId, VmId } from "../lib/ids.ts";
import type { TimedPhases } from "../lib/timing.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import type { TenantMayGrow } from "../proofs/tenant-may-grow.ts";
import type { TenantMayCreate } from "../proofs/tenant-may-create.ts";
import type { TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";

/** The operation a create refused by the provider create queue fails with (limits/create-admission.ts); nothing was sent. */
export const CREATE_QUEUE_FULL = "createQueueFull";

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
  maxRunTotalSeconds: Schema.optional(Schema.NullOr(Schema.Number)),
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

/** Provider-confirmed resources must satisfy every requested floor. */
export const resourceFloorsReached = (vm: UpstreamVm, size: SizeRequest): boolean =>
  (size.vcpus === undefined || vm.resources.cpu >= size.vcpus)
  && (size.memoryMib === undefined || vm.resources.memory >= size.memoryMib)
  && (size.diskMib === undefined || vm.resources.storage >= size.diskMib);

export interface CreateVmSpec {
  readonly createdBy?: string;
  /** Private effect journal: persist only the opaque request/context digest before provider I/O. */
  readonly journal: {
    readonly context: string | null;
    /**
     * The VM id was minted in this request (the key's ledger held no creation to resume), so no create can have been
     * sent for its slug yet. False on every resumed creation, whose earlier attempt may have sent one.
     */
    readonly minted: boolean;
    /** A resumed creation's retained source digest (its probe's `source`), when it booted a snapshot or an image. */
    readonly source: string | null;
    /** A resumed creation's retained request digest (its probe's `request`): what its VM carries as `cmux_create`. */
    readonly request: string | null;
    readonly beforeSend: (context: string, probe: VmCreationProbe) => Effect.Effect<void, UpstreamError>;
    readonly beginSend: () => Effect.Effect<string, UpstreamError>;
    readonly rejected: (token: string) => Effect.Effect<void, UpstreamError>;
    readonly active: Effect.Effect<void, UpstreamError>;
  };
  readonly cmuxId: VmId;
  readonly idleTimeoutSeconds: number;
  readonly maxRunSeconds?: number;
  readonly autoDeleteSeconds?: number;
  /** Without a source snapshot: the size to boot; picks the base image size. */
  readonly size?: SizeRequest;
  /** Deployment name (staging, production, ...), tagged on the upstream VM. */
  readonly environment: string;
  /**
   * The caller's switch (TenantPolicy.createsWithoutReads): no provider read before the create. The exact-slug read is
   * skipped only when `journal.minted`; the boot image read always. Absent: both reads come first.
   */
  readonly withoutReads?: boolean;
  /**
   * Filled as the create runs, for the handler's vm_create line: recoverMs, verifyImageMs, createMs, recoverAfterMs,
   * resizeMs (each only when that provider call was made), `recovered`, `imageVariant` for an approved image, and the
   * provider's own `providerTotalMs` and `providerTimingsMs` when its create answer carried them.
   */
  readonly phases?: TimedPhases;
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

export interface FileStatRecord {
  readonly kind: "file" | "directory" | "symlink" | "other";
  readonly size: number;
  readonly mode: number;
  readonly mtime: number | null;
  readonly owner: string;
  readonly group: string;
}

/** A per-VM client session the provider issued: shown to the caller once, never stored except the identity id. */
export interface ClientSessionGrant {
  /** The provider identity holding the grant and the token; internal, kept to revoke it. */
  readonly upstreamIdentityId: UpstreamId;
  /** The provider access token, scoped to this VM and Linux user. */
  readonly token: string;
  /** The provider's id of the VM: the token is used with it directly. */
  readonly providerVmId: UpstreamId;
  readonly apiBaseUrl: string;
  readonly sshHost: string;
}

export type Owns<C, R> = TenantOwnsResource<C, R>;
type Write<C> = KeyHasScope<C, "vm:write">;

export interface UpstreamClientService {
  /**
   * Mints a provider identity granted only this owned VM as `linuxUser`, and
   * one access token for it. A failure leaves no identity behind.
   */
  readonly openClientSession: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:exec"> },
    linuxUser: string,
  ) => Effect.Effect<ClientSessionGrant, UpstreamError>;
  /** Deletes a provider identity this service minted, with its tokens and grants; "gone" when it no longer existed. */
  readonly deleteIdentity: (identityId: UpstreamId) => Effect.Effect<"deleted" | "gone", UpstreamError>;
  /** Identifies this exact canonical allocation, without exposing its private provider ID. */
  readonly instanceFingerprint: <C, R>(vm: Named<R, VmId>, proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:read"> }) => Effect.Effect<string>;
  /** Reads saved-disk metadata without running guest code, including when retired. */
  readonly statFile: <C, R>(vm: Named<R, VmId>, proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:files"> }, path: string) => Effect.Effect<FileStatRecord, UpstreamError>;
  /** Irreversibly fences this owned VM; success requires a confirmed zero budget and no running compute. */
  readonly retireVm: <C, R>(vm: Named<R, VmId>, proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C> }) => Effect.Effect<UpstreamVm, UpstreamError>;
  /** Ensure resource floors on exactly this owned VM; never deletes it on failure. */
  readonly resizeVm: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C>; readonly mayGrow: TenantMayGrow<C> },
    size: SizeRequest,
  ) => Effect.Effect<UpstreamVm, UpstreamError>;
  readonly replaceVmHttpsProxy: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:network">; readonly network: VmNetworkAllowed<C> },
  ) => Effect.Effect<"updated" | "missing" | "ambiguous", UpstreamError>;
  /** Whether a rule whose source is exactly this VM allows the public Internet on every port. */
  readonly readVmPublicEgress: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:network"> },
  ) => Effect.Effect<boolean, UpstreamError>;
  /** Adds that rule unless one is there; never removes or widens another rule. */
  readonly allowVmPublicEgress: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:network"> },
  ) => Effect.Effect<void, UpstreamError>;
  /**
   * Deletes every such rule, then reads again and fails unless none is left; never touches a narrower rule, an
   * HTTPS proxy or a shared-network rule. Answers how many it deleted.
   */
  readonly revokeVmPublicEgress: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:network"> },
  ) => Effect.Effect<number, UpstreamError>;
  /** vm:files may read the state too: the paused-read replica answers only while the VM is unchanged. */
  readonly getVm: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:read"> | KeyHasScope<C, "vm:files"> },
  ) => Effect.Effect<UpstreamVm, UpstreamError>;
  /** Reads a VM's state on the way to changing it. */
  readonly getVmForWrite: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C> },
  ) => Effect.Effect<UpstreamVm, UpstreamError>;
  /**
   * Boots a new VM for the caller's tenant. Its upstream name and metadata
   * carry the tenant id and the cmux id; the tenant id is also its upstream customer. With `source`, it boots from that
   * snapshot of the tenant's.
   */
  readonly inspectCancellingCreation: <C, V>(caller: Named<C, Principal>, vm: Named<V, VmId>, proofs: { readonly scope: Write<C>; readonly cancelling: CancellingVmCreation<C, V> }) => Effect.Effect<{ readonly upstreamId: UpstreamId } | null, UpstreamError>;
  readonly deleteCancellingCreation: <C, V>(caller: Named<C, Principal>, vm: Named<V, VmId>, proofs: { readonly scope: Write<C>; readonly cancelling: CancellingVmCreation<C, V>; readonly owns: Owns<C, V> }) => Effect.Effect<void, UpstreamError>;
  readonly recoverCreation: <C, V>(caller: Named<C, Principal>, vm: Named<V, VmId>, proofs: { readonly scope: Write<C>; readonly pending: PendingVmCreation<C, V> }) => Effect.Effect<{ readonly upstreamId: UpstreamId } | null, UpstreamError>;
  readonly createVm: <C, S = never, M = never>(
    caller: Named<C, Principal>,
    spec: CreateVmSpec,
    proofs: {
      readonly mayCreate: TenantMayCreate<C, "vm">;
      readonly scope: Write<C>;
      readonly network?: VmNetworkAllowed<C>;
      readonly image?: VmImageAllowed<C>;
      readonly source?: { readonly snapshot: Named<S, SnapshotId>; readonly owns: Owns<C, S> };
      /** The tenant's mesh whose private network the VM joins in the provider's create (what attachVm does afterwards). */
      readonly mesh?: { readonly mesh: Named<M, MeshId>; readonly owns: Owns<C, M>; readonly scope: KeyHasScope<C, "mesh:write"> };
    },
  ) => Effect.Effect<
    CreatedResource & {
      readonly vm: UpstreamVm;
      /**
       * With `mesh`: the VM's IPv4 address on that mesh's network, when the provider's answer shows the VM on exactly
       * that network with one. Null otherwise (no mesh asked, or the answer does not show it): the caller then knows
       * nothing about the VM's networks, and attachVm (declarative, so safe to repeat) still puts it there.
       */
      readonly joined: { readonly ipv4: string } | null;
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

