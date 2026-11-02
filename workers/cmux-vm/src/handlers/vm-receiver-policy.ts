import type { Named } from "@gdp-ts/core";
import { Clock, Duration, Effect, Option, Schema } from "effect";
import { VmReceiverPolicy } from "../api/mesh.ts";
import { MeshStore } from "../db/mesh.ts";
import type { Principal } from "../domain/principal.ts";
import { unavailable, vmNotFound } from "../errors.ts";
import type { MeshId, VmId } from "../lib/ids.ts";
import { actorOf, ownerLease } from "../mesh/owner.ts";
import { sha256Hex } from "../mesh/signed-request.ts";
import { projectVmReceivers } from "../mesh/vm-receiver-policy.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { tenantOwnsMesh, tenantOwnsVm, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { dependencyDown } from "./common.ts";
import { readMeshMember } from "./mesh-member.ts";
import { compileMeshPolicy } from "./mesh-policy-inventory.ts";

/** Called under the mesh writer lock, with the same scope proofs as the member read. */
export const readVmReceiverPolicy = <C, M, V>(caller: Named<C, Principal>, mesh: Named<M, MeshId>, vm: Named<V, VmId>,
  proofs: { readonly ownsMesh: TenantOwnsResource<C, M>; readonly meshScope: KeyHasScope<C, "mesh:read">; readonly vmScope: KeyHasScope<C, "vm:read"> }) =>
  Effect.gen(function* () {
    const checkedAt = yield* Clock.currentTimeMillis, tenant = caller.value.tenantId, store = yield* MeshStore;
    const member = yield* readMeshMember(caller, mesh, vm, proofs);
    const acl = yield* store.currentAcl(tenant, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.currentAcl")));
    const aclFingerprint = JSON.stringify(acl);
    const document = Option.match(acl, { onNone: () => ({ rules: [] }), onSome: (v) => v.document });
    const version = Option.match(acl, { onNone: () => 0, onSome: (v) => v.version });
    const first = yield* compileMeshPolicy(tenant, mesh.value, document, false);
    const fingerprint = JSON.stringify(first);
    if (!first.result.ok || first.devices.length > 4096 || first.members.filter((m) => m.vmId === vm.value).length !== 1) return yield* Effect.fail(unavailable());
    const attached = first.members.find((m) => m.vmId === vm.value);
    if (attached === undefined || attached.meshId !== mesh.value || attached.ipv4 !== member.ipv4 || attached.attachedAt.toISOString() !== member.attachedAt) return yield* Effect.fail(vmNotFound());
    const candidates = projectVmReceivers(vm.value, first.devices, first.result.rules);
    if (candidates.length > 128 || candidates.reduce((sum, peer) => sum + peer.allow.length, 0) > 4096) return yield* Effect.fail(unavailable());
    const owners = [...new Set(first.devices.filter((d) => candidates.some((p) => p.deviceId === d.deviceId)).map((d) => d.createdBy))];
    const leases = new Map(yield* Effect.forEach(owners, (owner) => Effect.gen(function* () {
      const actor = actorOf(owner);
      return [owner, Option.isSome(actor) ? (yield* ownerLease(tenant, actor.value, true)) : Option.none<number | null>()] as const;
    }), { concurrency: 8 }));
    const peers = candidates.filter((p) => first.devices.some((d) => d.deviceId === p.deviceId && Option.isSome(leases.get(d.createdBy) ?? Option.none())));
    const expirations = [...leases.values()].flatMap((lease) => Option.isSome(lease) && lease.value !== null ? [lease.value] : []);
    const expiresAt = Math.min(checkedAt + 30_000, ...expirations);
    const projection = { schemaVersion: 1 as const, tenantId: tenant, vmId: vm.value, meshId: mesh.value, ipv4: member.ipv4, aclVersion: version, peers };
    const policyDigest = yield* sha256Hex(`cmux-vm-receiver-policy-v1\n${JSON.stringify(projection)}`);
    // Fence identity rotation, deletion, attachment and ACL changes across owner lookups.
    const again = yield* compileMeshPolicy(tenant, mesh.value, document, false);
    const currentAcl = yield* store.currentAcl(tenant, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.currentAcl")));
    const same = fingerprint === JSON.stringify(again) && aclFingerprint === JSON.stringify(currentAcl);
    const ownsMesh = yield* tenantOwnsMesh(caller, mesh).pipe(Effect.catchAll(dependencyDown("ownership.find")));
    const ownsVm = yield* tenantOwnsVm(caller, vm).pipe(Effect.catchAll(dependencyDown("ownership.find")));
    const finished = yield* Clock.currentTimeMillis;
    if (!same || ownsVm === null || ownsMesh === null || finished < checkedAt || finished >= expiresAt || !Number.isSafeInteger(version)) return yield* Effect.fail(unavailable());
    return yield* Schema.decodeUnknown(VmReceiverPolicy)({ ...projection, policyDigest, checkedAt, expiresAt }).pipe(Effect.mapError(() => unavailable()));
  }).pipe(Effect.timeoutFail({ duration: Duration.seconds(15), onTimeout: unavailable }));
