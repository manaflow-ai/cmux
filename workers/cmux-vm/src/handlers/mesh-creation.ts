/** Keyed mesh creation retains its identity, CIDR and quota until ownership is committed. */
import { name, type Named } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import { Mesh } from "../api/mesh.ts";
import { MeshStore } from "../db/mesh.ts";
import { OwnershipStore } from "../db/stores.ts";
import { actorRef, carriesRequiredLabels, type Principal } from "../domain/principal.ts";
import { Conflict, Forbidden, NotFound, PaymentRequired, QuotaExceeded, unavailable } from "../errors.ts";
import { newMeshId } from "../lib/ids.ts";
import type { MeshCreationCommand } from "../limits/mesh-creation.ts";
import { TenantLimits } from "../limits/service.ts";
import { MESH_SLOTS, slotCidr } from "../mesh/config.ts";
import { sha256Hex } from "../mesh/signed-request.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { MESH_CREATION_LABEL, pendingMeshCreation, pendingMeshCreationEvidenceOf } from "../proofs/mesh-creation.ts";
import { tenantMayCreateMesh } from "../proofs/mesh-may-create.ts";
import { tenantOwnsMesh } from "../proofs/tenant-owns-resource.ts";
import { UpstreamMesh, type CreatedNetwork } from "../upstream/mesh.ts";

export const createMeshWithKey = <C>(caller: Named<C, Principal>, scope: KeyHasScope<C, "mesh:write">, rawKey: string, payload: { readonly displayName?: string | undefined; readonly labels?: Readonly<Record<string, string>> | undefined }) => Effect.gen(function* () {
  const principal = caller.value, limits = yield* TenantLimits, store = yield* MeshStore, ownership = yield* OwnershipStore, upstream = yield* UpstreamMesh;
  // Scoped to the creating actor (service id, API key id or session user): no other credential can replay it.
  // A service keeps its creations across secret rotation because its id stays the same.
  const key = yield* sha256Hex(JSON.stringify(["mesh-create-v2", actorRef(principal.actor), rawKey]));
  const requestedLabels = payload.labels ?? {};
  if (Object.hasOwn(requestedLabels, MESH_CREATION_LABEL)) return yield* Effect.fail(new Forbidden({ message: "The mesh creation label is reserved" }));
  const labels = { ...requestedLabels, [MESH_CREATION_LABEL]: key };
  const hidden = () => new NotFound({ message: "Mesh not found" });
  if (!carriesRequiredLabels(principal, labels)) return yield* Effect.fail(new Forbidden({ message: "This credential cannot create this mesh" }));
  // A selected-resource key can replay a permitted mesh, but cannot claim an unknown intent.
  if (principal.resourceAllowlist !== null) {
    const prior = yield* limits.meshCreation(principal.tenantId, { op: "get", key }).pipe(Effect.mapError(() => unavailable()));
    if (prior.state !== "record" || !principal.resourceAllowlist.has(prior.record.meshId)) return yield* Effect.fail(hidden());
  }
  const holder = crypto.randomUUID();
  const ordered = Object.entries(requestedLabels).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
  const fingerprint = yield* sha256Hex(JSON.stringify(ordered.length === 0 ? ["mesh-create-v1", payload.displayName ?? null] : ["mesh-create-labelled-v1", payload.displayName ?? null, ordered]));
  const intent = { key, fingerprint, meshId: newMeshId(), holder, createdBy: actorRef(principal.actor), displayName: payload.displayName ?? null };
  const begun = yield* limits.meshCreation(principal.tenantId, ordered.length === 0 ? { op: "begin", ...intent } : { op: "begin-labelled", ...intent, labels }).pipe(Effect.mapError(() => unavailable()));
  if (begun.state === "conflict") return yield* Effect.fail(new Conflict({ message: "This mesh creation key was used for a different request" }));
  if (begun.state !== "record") return yield* Effect.fail(unavailable());
  const { record } = begun;
  const retainedLabels = record.labels ?? { [MESH_CREATION_LABEL]: key };
  if (retainedLabels[MESH_CREATION_LABEL] !== key || !carriesRequiredLabels(principal, retainedLabels)) return yield* Effect.fail(new Forbidden({ message: "This credential cannot reach the retained mesh" }));
  return yield* name(record.meshId, (mesh) => Effect.gen(function* () {
    if (principal.resourceAllowlist !== null && !principal.resourceAllowlist.has(mesh.value)) return yield* Effect.fail(hidden());
    if (record.phase === "cancelling" || record.phase === "deleted") return yield* Effect.fail(hidden());
    const journal = (command: MeshCreationCommand) => limits.meshCreation(principal.tenantId, command).pipe(
      Effect.mapError(() => unavailable()), Effect.flatMap((result) => result.state === "record" ? Effect.void : Effect.fail(unavailable())),
    );
    // Ownership is authoritative and replay precedes entitlement and quota checks.
    const owns = yield* tenantOwnsMesh(caller, mesh).pipe(Effect.mapError(() => unavailable()));
    if (owns !== null) {
      const row = yield* ownership.find(principal.tenantId, "mesh", mesh.value).pipe(Effect.mapError(() => unavailable()));
      const cidr = yield* store.cidrOf(principal.tenantId, mesh.value).pipe(Effect.mapError(() => unavailable()));
      if (Option.isNone(row) || Option.isNone(cidr)) return yield* Effect.fail(unavailable());
      yield* journal({ op: "complete", key, meshId: mesh.value });
      return new Mesh({ id: mesh.value, displayName: row.value.displayName, ipv4Cidr: cidr.value, createdAt: row.value.createdAt.toISOString() });
    }
    if (record.phase === "done") return yield* Effect.fail(hidden());
    if (!begun.acquired) return yield* Effect.fail(new Conflict({ message: "Mesh creation is in progress; retry with the same key" }));
    const work = Effect.gen(function* () {
      const commit = (created: CreatedNetwork, active: Effect.Effect<void, unknown>) => Effect.gen(function* () {
        yield* active.pipe(Effect.mapError(() => unavailable()));
        yield* ownership.record({ tenantId: principal.tenantId, kind: "mesh", cmuxId: mesh.value, upstreamId: created.upstreamId,
          createdBy: record.createdBy, createdAt: new Date(record.createdAt), displayName: record.displayName, labels: retainedLabels }).pipe(Effect.mapError(() => unavailable()));
        yield* journal({ op: "complete", key, meshId: mesh.value });
        return new Mesh({ id: mesh.value, displayName: record.displayName, ipv4Cidr: created.cidr, createdAt: record.createdAt });
      });
      if (record.dispatch.state === "sent") {
        const pending = yield* pendingMeshCreation(caller, mesh, key, holder).pipe(Effect.mapError(() => unavailable()));
        if (pending === null) return yield* Effect.fail(unavailable());
        const found = yield* upstream.recoverNetwork(mesh, { scope, pending }).pipe(Effect.mapError(() => unavailable()));
        if (Option.isNone(found)) return yield* Effect.fail(unavailable());
        return yield* commit(found.value, pendingMeshCreationEvidenceOf(pending).active);
      }
      const decision = yield* tenantMayCreateMesh(caller, record.reservationId === null ? undefined : { key, meshId: mesh.value }).pipe(Effect.mapError(() => unavailable()));
      if (decision._tag === "not_entitled") return yield* Effect.fail(new PaymentRequired({ message: "The team's plan does not include meshes" }));
      if (decision._tag === "over_budget") return yield* Effect.fail(new QuotaExceeded({ message: "The team's mesh limit has been reached", budget: "mesh.perTenant" }));
      const mayCreate = decision.proof;
      return yield* Effect.gen(function* () {
        yield* journal({ op: "retain", key, meshId: mesh.value, holder, reservationId: mayCreate.reservationId });
        let cidr = yield* store.cidrOf(principal.tenantId, mesh.value).pipe(Effect.mapError(() => unavailable()));
        if (Option.isNone(cidr) && record.context !== null) return yield* Effect.fail(unavailable());
        for (let attempt = 0; attempt < 8 && Option.isNone(cidr); attempt++) {
          const slot = Math.floor(Math.random() * MESH_SLOTS), candidate = slotCidr(slot);
          const claimed = yield* store.claimSlot(principal.tenantId, mesh.value, slot, candidate).pipe(Effect.mapError(() => unavailable()));
          cidr = claimed ? Option.some(candidate) : yield* store.cidrOf(principal.tenantId, mesh.value).pipe(Effect.mapError(() => unavailable()));
        }
        if (Option.isNone(cidr)) return yield* Effect.fail(unavailable());
        const pending = yield* pendingMeshCreation(caller, mesh, key, holder).pipe(Effect.mapError(() => unavailable()));
        if (pending === null) return yield* Effect.fail(unavailable());
        const created = yield* upstream.createJournalledNetwork(mesh, { scope, mayCreate, pending }).pipe(Effect.mapError(() => unavailable()));
        // Unknown sends and failed ownership writes keep the exact network and quota for recovery.
        return yield* commit(created, pendingMeshCreationEvidenceOf(pending).active);
      }).pipe(Effect.ensuring(limits.release(principal.tenantId, mayCreate.reservationId)));
    });
    return yield* work;
  })).pipe(Effect.ensuring(begun.acquired ? limits.meshCreation(principal.tenantId, { op: "abandon", key, meshId: record.meshId, holder }).pipe(Effect.ignore) : Effect.void));
}).pipe(Effect.uninterruptible);
