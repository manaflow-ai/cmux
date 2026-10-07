/**
 * Trusted module: the only place a TenantOwnsResource proof is minted.
 *
 * The upstream id the ownership lookup found is the proof's evidence. It is
 * kept in a module-private WeakMap keyed by the exact proof object, never on
 * the proof itself, so a copied or hand-built proof (`{ ...proof }`) carries
 * no upstream id and cannot be pointed at another resource. Only code holding
 * a minted proof can read the id, through `upstreamIdOf`.
 */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import { OwnershipStore } from "../db/stores.ts";
import type { StoreError } from "../db/sql.ts";
import type { Principal } from "../domain/principal.ts";
import type { ResourceKind, SnapshotId, UpstreamId, VmId } from "../lib/ids.ts";

const TenantOwnsResource = defineProof("TenantOwnsResource");

/** The tenant of caller `C` owns the public resource named `R`, and `C` may reach it. */
export interface TenantOwnsResource<C, R> extends Proof<"TenantOwnsResource", [C, R]> {}

const evidence = new WeakMap<object, UpstreamId>();

/** The upstream id this proof was minted for. A proof not minted here has none. */
export const upstreamIdOf = <C, R>(proof: TenantOwnsResource<C, R>): UpstreamId => {
  const upstreamId = evidence.get(proof);
  if (upstreamId === undefined) throw new Error("TenantOwnsResource proof was not minted by src/proofs");
  return upstreamId;
};

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
    // A fresh object per mint: the WeakMap entry belongs to this proof only.
    const proof: TenantOwnsResource<C, R> = Object.freeze({ ...TenantOwnsResource.prove(caller, resource) });
    evidence.set(proof, found.value.upstreamId);
    return proof;
  });

export const tenantOwnsVm = <C, R>(caller: Named<C, Principal>, vm: Named<R, VmId>) => owns(caller, vm, "vm");

export const tenantOwnsSnapshot = <C, R>(caller: Named<C, Principal>, snapshot: Named<R, SnapshotId>) =>
  owns(caller, snapshot, "snapshot");
