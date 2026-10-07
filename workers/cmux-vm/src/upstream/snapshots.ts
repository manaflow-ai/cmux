/**
 * Provider snapshot operations. Every method demands gdp-ts proofs about its
 * exact named arguments: ownership of the VM or snapshot (which carries the
 * provider id), the scope, and for creates the tenant's entitlement.
 * See upstream/PINNED.json for the pinned provider API surface.
 */
import type { Named } from "@gdp-ts/core";
import { Context, Effect, Schema } from "effect";
import { UpstreamId, type SnapshotId, type TenantId, type VmId } from "../lib/ids.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import type { TenantMayCreate } from "../proofs/tenant-may-create.ts";
import type { TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { UpstreamError, type UpstreamConfig } from "./client.ts";
import { makeUpstreamHttp, proofSegment } from "./http.ts";

/** The fields of the provider's snapshot record this service reads. Everything else is ignored. */
export const UpstreamSnapshot = Schema.Struct({
  createdAt: Schema.String,
  lastUsedAt: Schema.optional(Schema.NullOr(Schema.String)),
  ttlSeconds: Schema.optional(Schema.NullOr(Schema.Number)),
  autoDeleteSeconds: Schema.optional(Schema.NullOr(Schema.Number)),
});
export type UpstreamSnapshot = typeof UpstreamSnapshot.Type;

const SnapshotCreated = Schema.Struct({ snapshotId: UpstreamId, snapshot: UpstreamSnapshot });

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
  readonly getSnapshot: <C, S>(
    snapshot: Named<S, SnapshotId>,
    proofs: { readonly owns: TenantOwnsResource<C, S>; readonly scope: KeyHasScope<C, "snapshot:read"> },
  ) => Effect.Effect<UpstreamSnapshot, UpstreamError>;
  readonly deleteSnapshot: <C, S>(
    snapshot: Named<S, SnapshotId>,
    proofs: { readonly owns: TenantOwnsResource<C, S>; readonly scope: KeyHasScope<C, "snapshot:write"> },
  ) => Effect.Effect<void, UpstreamError>;
}

export class UpstreamSnapshots extends Context.Tag("cmux-vm/UpstreamSnapshots")<UpstreamSnapshots, UpstreamSnapshotsService>() {}

const decodeAs =
  <A, I>(schema: Schema.Schema<A, I>, operation: string) =>
  (body: unknown): Effect.Effect<A, UpstreamError> =>
    Schema.decodeUnknown(schema)(body).pipe(Effect.mapError(() => new UpstreamError({ operation, status: null })));

export function makeUpstreamSnapshots(config: UpstreamConfig): UpstreamSnapshotsService {
  const http = makeUpstreamHttp(config);
  const created = new WeakSet<CreatedSnapshot>();

  return {
    createSnapshot: (_vm, { owns }, options) =>
      http
        .json("createSnapshot", "POST", `/v5/vms/${proofSegment(owns)}/snapshot`, {
          displayName: `cmux ${options.tenantId} ${options.snapshotId}`,
          ...(options.ttlSeconds === undefined ? {} : { ttlSeconds: options.ttlSeconds }),
          ...(options.autoDeleteSeconds === undefined ? {} : { autoDeleteSeconds: options.autoDeleteSeconds }),
        })
        .pipe(
          Effect.flatMap(decodeAs(SnapshotCreated, "createSnapshot")),
          Effect.map((body) => {
            const result: CreatedSnapshot = Object.freeze({ upstreamId: body.snapshotId, snapshot: body.snapshot });
            created.add(result);
            return result;
          }),
        ),
    discardCreatedSnapshot: (result) =>
      created.has(result)
        ? http
            .json("discardCreatedSnapshot", "DELETE", `/v5/snapshots/${encodeURIComponent(result.upstreamId)}`)
            .pipe(Effect.asVoid)
        : Effect.fail(new UpstreamError({ operation: "discardCreatedSnapshot", status: null })),
    getSnapshot: (_snapshot, { owns }) =>
      http
        .json("getSnapshot", "GET", `/v5/snapshots/${proofSegment(owns)}`)
        .pipe(Effect.flatMap(decodeAs(UpstreamSnapshot, "getSnapshot"))),
    deleteSnapshot: (_snapshot, { owns }) =>
      http.json("deleteSnapshot", "DELETE", `/v5/snapshots/${proofSegment(owns)}`).pipe(Effect.asVoid),
  };
}
