/**
 * Provider snapshot operations, as handlers see them; the implementation that
 * holds the provider key is src/upstream/live-snapshots.ts. Every method
 * demands gdp-ts proofs about its exact named arguments: ownership of the VM or snapshot (which carries the
 * provider id), the scope, and for creates the tenant's entitlement.
 * See upstream/PINNED.json for the pinned provider API surface.
 */
import type { Named } from "@gdp-ts/core";
import { Context, Effect, Schema } from "effect";
import type { SnapshotId, TenantId, UpstreamId, VmId } from "../lib/ids.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import type { TenantMayCreate } from "../proofs/tenant-may-create.ts";
import type { TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import type { UpstreamError } from "./client.ts";

/** The fields of the provider's snapshot record this service reads. Everything else is ignored. */
export const UpstreamSnapshot = Schema.Struct({
  createdAt: Schema.String,
  lastUsedAt: Schema.optional(Schema.NullOr(Schema.String)),
  ttlSeconds: Schema.optional(Schema.NullOr(Schema.Number)),
  autoDeleteSeconds: Schema.optional(Schema.NullOr(Schema.Number)),
});
export type UpstreamSnapshot = typeof UpstreamSnapshot.Type;

/** A snapshot the provider just created. Only `createSnapshot` makes one. */
export interface CreatedSnapshot {
  readonly upstreamId: UpstreamId;
  readonly snapshot: UpstreamSnapshot;
}

export interface CreateSnapshotOptions {
  /** Written into the provider's display name so a leaked provider id is still attributable. */
  readonly tenantId: TenantId;
  readonly snapshotId: SnapshotId;
  readonly ttlSeconds?: number | undefined;
  readonly autoDeleteSeconds?: number | undefined;
}

export interface UpstreamSnapshotsService {
  readonly createSnapshot: <C, V>(
    vm: Named<V, VmId>,
    proofs: {
      readonly owns: TenantOwnsResource<C, V>;
      readonly scope: KeyHasScope<C, "snapshot:write">;
      readonly mayCreate: TenantMayCreate<C, "snapshot">;
    },
    options: CreateSnapshotOptions,
  ) => Effect.Effect<CreatedSnapshot, UpstreamError>;
  /** Undoes a create whose ownership row could not be written. Accepts only a value `createSnapshot` returned. */
  readonly discardCreatedSnapshot: (created: CreatedSnapshot) => Effect.Effect<void, UpstreamError>;
  /** Reading needs snapshot:read; a create replaying its own result reads with the snapshot:write it was proven. */
  readonly getSnapshot: <C, S>(
    snapshot: Named<S, SnapshotId>,
    proofs: {
      readonly owns: TenantOwnsResource<C, S>;
      readonly scope: KeyHasScope<C, "snapshot:read"> | KeyHasScope<C, "snapshot:write">;
    },
  ) => Effect.Effect<UpstreamSnapshot, UpstreamError>;
  readonly deleteSnapshot: <C, S>(
    snapshot: Named<S, SnapshotId>,
    proofs: { readonly owns: TenantOwnsResource<C, S>; readonly scope: KeyHasScope<C, "snapshot:write"> },
  ) => Effect.Effect<void, UpstreamError>;
}

export class UpstreamSnapshots extends Context.Tag("cmux-vm/UpstreamSnapshots")<UpstreamSnapshots, UpstreamSnapshotsService>() {}

