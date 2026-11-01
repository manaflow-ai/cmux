import type { Named } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import { MeshMember } from "../api/mesh.ts";
import { MeshStore } from "../db/mesh.ts";
import type { Principal } from "../domain/principal.ts";
import { Conflict, unavailable, vmNotFound } from "../errors.ts";
import type { MeshId, VmId } from "../lib/ids.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { tenantOwnsMesh, tenantOwnsVm, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { UpstreamMesh } from "../upstream/mesh.ts";
import { dependencyDown } from "./common.ts";

const addressInMesh = (address: string, cidr: string): boolean => {
  const numbers = (text: string) => text.split(".").map(Number);
  const ip = numbers(address), base = numbers(cidr.split("/")[0] ?? "");
  if (!cidr.endsWith("/20") || ip.length !== 4 || base.length !== 4
    || ip.some((n) => !Number.isInteger(n) || n < 0 || n > 255) || ip.join(".") !== address) return false;
  return ip[0] === base[0] && ip[1] === base[1] && Math.floor(ip[2]! / 16) === Math.floor(base[2]! / 16)
    && !(ip[2] === base[2] && ip[3] === 0) && !(ip[2] === base[2]! + 15 && ip[3] === 255);
};

/** Called under the mesh writer lease; only this exact live attachment is refreshed. */
export const readMeshMember = <C, M, V>(caller: Named<C, Principal>, mesh: Named<M, MeshId>, vm: Named<V, VmId>,
  proofs: { readonly ownsMesh: TenantOwnsResource<C, M>; readonly meshScope: KeyHasScope<C, "mesh:read">; readonly vmScope: KeyHasScope<C, "vm:read"> }) =>
  Effect.gen(function* () {
    const tenant = caller.value.tenantId, store = yield* MeshStore, upstream = yield* UpstreamMesh;
    const ownsVm = yield* tenantOwnsVm(caller, vm).pipe(Effect.catchAll(dependencyDown("ownership.find")));
    if (ownsVm === null) return yield* Effect.fail(vmNotFound());
    const current = yield* store.memberOf(tenant, vm.value).pipe(Effect.catchAll(dependencyDown("mesh.memberOf")));
    if (Option.isNone(current) || current.value.meshId !== mesh.value) return yield* Effect.fail(vmNotFound());
    const { ipv4 } = yield* upstream.readVmAddress(mesh, vm, { ...proofs, ownsVm }).pipe(Effect.mapError(() => unavailable()));
    const cidr = yield* store.cidrOf(tenant, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.cidrOf")));
    if (Option.isNone(cidr) || (ipv4 !== null && !addressInMesh(ipv4, cidr.value))) return yield* Effect.fail(unavailable());
    const liveVm = yield* tenantOwnsVm(caller, vm).pipe(Effect.catchAll(dependencyDown("ownership.find")));
    const liveMesh = yield* tenantOwnsMesh(caller, mesh).pipe(Effect.catchAll(dependencyDown("ownership.find")));
    if (liveVm === null || liveMesh === null) return yield* Effect.fail(vmNotFound());
    const applied = yield* store.updateMemberAddress(tenant, current.value, ipv4).pipe(Effect.catchAll(dependencyDown("mesh.updateMemberAddress")));
    if (!applied) return yield* Effect.fail(new Conflict({ message: "The VM's mesh attachment changed; retry" }));
    return new MeshMember({ meshId: mesh.value, vmId: vm.value, ipv4, attachedAt: current.value.attachedAt.toISOString() });
  });
