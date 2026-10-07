/**
 * Trusted module: the only place a TenantOwnsResource proof is minted.
 *
 * The proof carries the upstream id it found as evidence. That is the only way
 * code outside the stores can obtain an upstream id, so an upstream call cannot
 * be pointed at a resource the ownership table did not resolve for this caller.
 */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import { OwnershipStore } from "../db/stores.ts";
import type { StoreError } from "../db/sql.ts";
import type { Principal } from "../domain/principal.ts";
import type { ResourceKind, SnapshotId, UpstreamId, VmId } from "../lib/ids.ts";

const TenantOwnsResource = defineProof("TenantOwnsResource");

/** The tenant of caller `C` owns the public resource named `R`, and `C` may reach it. */
export interface TenantOwnsResource<C, R> extends Proof<"TenantOwnsResource", [C, R]> {
  readonly upstreamId: UpstreamId;
}

const owns = <C, R>(
  caller: Named<C, Principal>,
  resource: Named<R, VmId | SnapshotId>,
  kind: ResourceKind,
): Effect.Effect<TenantOwnsResource<C, R> | null, StoreError, OwnershipStore> =>
  Effect.gen(function* () {
    const principal = caller.value;
    if (principal.resourceAllowlist !== null && !principal.resourceAllowlist.has(resource.value)) return null;
    const store = yield* OwnershipStore;
    const found = yield* store.find(principal.tenantId, kind, resource.value);
    if (Option.isNone(found) || found.value.tenantId !== principal.tenantId) return null;
    const proof: TenantOwnsResource<C, R> = Object.freeze({
      ...TenantOwnsResource.prove(caller, resource),
      upstreamId: found.value.upstreamId,
    });
    return proof;
  });

export const tenantOwnsVm = <C, R>(caller: Named<C, Principal>, vm: Named<R, VmId>) => owns(caller, vm, "vm");

export const tenantOwnsSnapshot = <C, R>(caller: Named<C, Principal>, snapshot: Named<R, SnapshotId>) =>
  owns(caller, snapshot, "snapshot");
