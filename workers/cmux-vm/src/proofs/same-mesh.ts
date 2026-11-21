/**
 * Trusted module: the only place SameMesh and OwnedMeshRule proofs are minted
 * (mesh experiment, cx-0op, DESIGN.md section 5).
 *
 * SameMesh<C, M, R>: resource R (a device or a VM) is a live member of mesh
 * M, and M belongs to caller C's tenant. Firewall rules are created only from
 * two such proofs, so a rule can never name another tenant's tunnel or VM,
 * even with a leaked provider id: the provider id of each end is the proof's
 * evidence, read from the ownership table of the caller's tenant.
 *
 * OwnedMeshRule<C, M>: a provider firewall rule that mesh M's ACL created, read
 * from the mesh's own rule table. Deleting a rule needs one, so the Worker can
 * only ever delete rules it made for this mesh.
 *
 * Evidence lives in module-private WeakMaps keyed by the exact proof object,
 * as in tenant-owns-resource.ts.
 */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import { MeshStore, type MeshRuleRow } from "../db/mesh.ts";
import type { StoreError } from "../db/sql.ts";
import { OwnershipStore, type OwnedResource } from "../db/stores.ts";
import type { Principal } from "../domain/principal.ts";
import type { DeviceId, MeshId, UpstreamId, VmId } from "../lib/ids.ts";
import { isAddressRuleKey } from "../mesh/acl.ts";
import type { TenantOwnsResource } from "./tenant-owns-resource.ts";

const SameMeshProof = defineProof("SameMesh");
const OwnedMeshRuleProof = defineProof("OwnedMeshRule");

/** Resource `R` is a live member of mesh `M` of caller `C`'s tenant. */
export interface SameMesh<C, M, R> extends Proof<"SameMesh", [C, M, R]> {
  readonly memberKind: "device" | "vm";
}

/** A provider rule mesh `M` of caller `C`'s tenant created. */
export interface OwnedMeshRule<C, M> extends Proof<"OwnedMeshRule", [C, M]> {
  /** The rule's public view, without its provider id. */
  readonly rule: Omit<MeshRuleRow, "upstreamRuleId">;
}

const endpoints = new WeakMap<object, UpstreamId>();
const ruleIds = new WeakMap<object, string>();

/** The provider id of a SameMesh proof's resource: the device's tunnel, or the VM. */
export const endpointOf = <C, M, R>(proof: SameMesh<C, M, R>): UpstreamId => {
  const id = endpoints.get(proof);
  if (id === undefined) throw new Error("SameMesh proof was not minted by src/proofs");
  return id;
};

/** The provider id of an OwnedMeshRule proof's rule. */
export const ruleIdOf = <C, M>(proof: OwnedMeshRule<C, M>): string => {
  const id = ruleIds.get(proof);
  if (id === undefined) throw new Error("OwnedMeshRule proof was not minted by src/proofs");
  return id;
};

/** Device `device` is enrolled in `mesh`, and both belong to the caller's tenant. */
export const sameMeshDevice = <C, M, R>(
  caller: Named<C, Principal>,
  mesh: Named<M, MeshId>,
  _ownsMesh: TenantOwnsResource<C, M>,
  device: Named<R, DeviceId>,
): Effect.Effect<SameMesh<C, M, R> | null, StoreError, OwnershipStore | MeshStore> =>
  Effect.gen(function* () {
    const tenantId = caller.value.tenantId;
    const owned = yield* (yield* OwnershipStore).find(tenantId, "device", device.value);
    if (Option.isNone(owned) || owned.value.tenantId !== tenantId) return null;
    const row = yield* (yield* MeshStore).getDevice(tenantId, device.value);
    if (Option.isNone(row) || row.value.meshId !== mesh.value) return null;
    const proof: SameMesh<C, M, R> = Object.freeze({ ...SameMeshProof.prove(caller, mesh, device), memberKind: "device" });
    endpoints.set(proof, owned.value.upstreamId);
    return proof;
  });

/** VM `vm` is a member of `mesh`, and both belong to the caller's tenant. */
export const sameMeshVm = <C, M, R>(
  caller: Named<C, Principal>,
  mesh: Named<M, MeshId>,
  _ownsMesh: TenantOwnsResource<C, M>,
  vm: Named<R, VmId>,
): Effect.Effect<SameMesh<C, M, R> | null, StoreError, OwnershipStore | MeshStore> =>
  Effect.gen(function* () {
    const tenantId = caller.value.tenantId;
    const owned = yield* (yield* OwnershipStore).find(tenantId, "vm", vm.value);
    if (Option.isNone(owned) || owned.value.tenantId !== tenantId) return null;
    const member = yield* (yield* MeshStore).memberOf(tenantId, vm.value);
    if (Option.isNone(member) || member.value.meshId !== mesh.value) return null;
    const proof: SameMesh<C, M, R> = Object.freeze({ ...SameMeshProof.prove(caller, mesh, vm), memberKind: "vm" });
    endpoints.set(proof, owned.value.upstreamId);
    return proof;
  });

/**
 * SameMesh proofs for many devices and VMs from one read of the mesh: the
 * same checks as sameMeshDevice and sameMeshVm (an ownership row of the
 * caller's tenant, a live device row or member row of exactly `mesh`), read
 * with two ownership queries and two mesh queries instead of two queries per
 * rule. An ACL apply that creates one rule per (device, VM, port) needs a
 * proof for each end of every rule; read per rule, a new VM in a mesh of 40
 * devices cost hundreds of sequential database round trips on the request's
 * one connection. Take it under the mesh's writer, right before the creates.
 */
export interface SameMeshSnapshot<C, M> {
  readonly device: <R>(device: Named<R, DeviceId>) => SameMesh<C, M, R> | null;
  readonly vm: <R>(vm: Named<R, VmId>) => SameMesh<C, M, R> | null;
}

export const sameMeshSnapshot = <C, M>(
  caller: Named<C, Principal>,
  mesh: Named<M, MeshId>,
  _ownsMesh: TenantOwnsResource<C, M>,
  deviceIds: ReadonlyArray<string>,
  vmIds: ReadonlyArray<string>,
): Effect.Effect<SameMeshSnapshot<C, M>, StoreError, OwnershipStore | MeshStore> =>
  Effect.gen(function* () {
    const tenantId = caller.value.tenantId;
    const ownership = yield* OwnershipStore;
    const store = yield* MeshStore;
    const [ownedDevices, ownedVms, devices, members] = yield* Effect.all(
      [
        ownership.findMany(tenantId, "device", [...new Set(deviceIds)]),
        ownership.findMany(tenantId, "vm", [...new Set(vmIds)]),
        deviceIds.length === 0 ? Effect.succeed([]) : store.listDevices(tenantId, mesh.value),
        vmIds.length === 0 ? Effect.succeed([]) : store.listMembers(tenantId, mesh.value),
      ],
      { concurrency: "unbounded" },
    );
    const liveDevices = new Set(devices.filter((row) => row.meshId === mesh.value).map((row) => row.deviceId));
    const liveVms = new Set(members.filter((row) => row.meshId === mesh.value).map((row) => row.vmId));
    const prove = <R>(resource: Named<R, DeviceId | VmId>, owned: ReadonlyMap<string, OwnedResource>, live: ReadonlySet<string>, memberKind: "device" | "vm") => {
      const row = owned.get(resource.value);
      if (row === undefined || row.tenantId !== tenantId || !live.has(resource.value)) return null;
      const proof: SameMesh<C, M, R> = Object.freeze({ ...SameMeshProof.prove(caller, mesh, resource), memberKind });
      endpoints.set(proof, row.upstreamId);
      return proof;
    };
    return {
      device: (device) => prove(device, ownedDevices, liveDevices, "device"),
      vm: (vm) => prove(vm, ownedVms, liveVms, "vm"),
    };
  });

/** Every live provider rule mesh `mesh` created, each with its proof. */
export const ownedMeshRules = <C, M>(
  caller: Named<C, Principal>,
  mesh: Named<M, MeshId>,
  _ownsMesh: TenantOwnsResource<C, M>,
): Effect.Effect<ReadonlyArray<OwnedMeshRule<C, M>>, StoreError, MeshStore> =>
  Effect.gen(function* () {
    const rows = yield* (yield* MeshStore).listRules(caller.value.tenantId, mesh.value);
    return rows
      .filter((row) => row.meshId === mesh.value)
      .map((row) => {
        const { upstreamRuleId, ...rule } = row;
        const proof: OwnedMeshRule<C, M> = Object.freeze({ ...OwnedMeshRuleProof.prove(caller, mesh), rule });
        ruleIds.set(proof, upstreamRuleId);
        return proof;
      });
  });

/**
 * The live address rules (cidr source, src/mesh/acl.ts) mesh `mesh` created
 * for device `device`, each with its proof; empty unless the device is a live
 * device of `mesh` in the caller's tenant. Closing a device deletes these at
 * the provider itself: unlike tunnel rules they name no tunnel, so deleting
 * the device's tunnel does not take them along.
 */
export const ownedDeviceAddressRules = <C, M, D>(
  caller: Named<C, Principal>,
  mesh: Named<M, MeshId>,
  _ownsDevice: TenantOwnsResource<C, D>,
  device: Named<D, DeviceId>,
): Effect.Effect<ReadonlyArray<OwnedMeshRule<C, M>>, StoreError, MeshStore> =>
  Effect.gen(function* () {
    const store = yield* MeshStore;
    const tenantId = caller.value.tenantId;
    const row = yield* store.getDevice(tenantId, device.value);
    if (Option.isNone(row) || row.value.meshId !== mesh.value) return [];
    const rows = yield* store.listRules(tenantId, mesh.value);
    return rows
      .filter((rule) => rule.meshId === mesh.value && rule.deviceId === device.value && isAddressRuleKey(rule.key))
      .map((rule) => {
        const { upstreamRuleId, ...view } = rule;
        const proof: OwnedMeshRule<C, M> = Object.freeze({ ...OwnedMeshRuleProof.prove(caller, mesh), rule: view });
        ruleIds.set(proof, upstreamRuleId);
        return proof;
      });
  });
