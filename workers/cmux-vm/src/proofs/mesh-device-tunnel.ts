/**
 * Trusted module: the only place MeshDeviceTunnel proofs are minted (mesh
 * networking parity, cx-0op).
 *
 * MeshDeviceTunnel<C, M>: the device named by the proof's public `deviceId` is
 * a live gateway device of mesh M, and both belong to caller C's tenant. Its
 * evidence is the device's provider tunnel id, read from the ownership table
 * of the caller's tenant (a device's provider id is its tunnel's), so a
 * listing of the mesh's network can only ever be matched back to this
 * tenant's own devices.
 *
 * Evidence lives in a module-private WeakMap keyed by the exact proof object,
 * as in tenant-owns-resource.ts.
 */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import { MeshStore } from "../db/mesh.ts";
import type { StoreError } from "../db/sql.ts";
import { OwnershipStore } from "../db/stores.ts";
import type { Principal } from "../domain/principal.ts";
import type { MeshId, UpstreamId } from "../lib/ids.ts";
import type { TenantOwnsResource } from "./tenant-owns-resource.ts";

const MeshDeviceTunnelProof = defineProof("MeshDeviceTunnel");

/** A live gateway device of mesh `M` of caller `C`'s tenant, by its public id. */
export interface MeshDeviceTunnel<C, M> extends Proof<"MeshDeviceTunnel", [C, M]> {
  readonly deviceId: string;
}

const tunnels = new WeakMap<object, UpstreamId>();

/** The provider tunnel id of a MeshDeviceTunnel proof's device. */
export const deviceTunnelIdOf = <C, M>(proof: MeshDeviceTunnel<C, M>): UpstreamId => {
  const id = tunnels.get(proof);
  if (id === undefined) throw new Error("MeshDeviceTunnel proof was not minted by src/proofs");
  return id;
};

/** A proof for each of `deviceIds` that is a live device of `mesh` in the caller's tenant; any other id is left out. */
export const meshDeviceTunnels = <C, M>(
  caller: Named<C, Principal>,
  mesh: Named<M, MeshId>,
  _ownsMesh: TenantOwnsResource<C, M>,
  deviceIds: ReadonlyArray<string>,
): Effect.Effect<ReadonlyArray<MeshDeviceTunnel<C, M>>, StoreError, OwnershipStore | MeshStore> =>
  Effect.gen(function* () {
    const tenantId = caller.value.tenantId;
    const ownership = yield* OwnershipStore;
    const store = yield* MeshStore;
    const proofs: Array<MeshDeviceTunnel<C, M>> = [];
    for (const deviceId of deviceIds) {
      const row = yield* store.getDevice(tenantId, deviceId);
      if (Option.isNone(row) || row.value.meshId !== mesh.value) continue;
      const owned = yield* ownership.find(tenantId, "device", deviceId);
      if (Option.isNone(owned) || owned.value.tenantId !== tenantId) continue;
      const proof: MeshDeviceTunnel<C, M> = Object.freeze({ ...MeshDeviceTunnelProof.prove(caller, mesh), deviceId });
      tunnels.set(proof, owned.value.upstreamId);
      proofs.push(proof);
    }
    return proofs;
  });
