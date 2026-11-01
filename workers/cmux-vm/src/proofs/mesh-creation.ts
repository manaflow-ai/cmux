/** Trusted: only retained, tenant-scoped mesh intent can authorize lookup of an uncommitted network. */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import { TeamAdmin } from "../auth/team-admin.ts";
import { MeshStore } from "../db/mesh.ts";
import { carriesRequiredLabels, type Principal } from "../domain/principal.ts";
import type { MeshId, TenantId } from "../lib/ids.ts";
import type { MeshCreationCommand, MeshCreationRecord } from "../limits/mesh-creation.ts";
import { TenantLimits } from "../limits/service.ts";
import { UpstreamError } from "../upstream/client.ts";

export const MESH_CREATION_LABEL = "cmux_mesh_creation";
export interface PendingMeshCreation<C, M> extends Proof<"PendingMeshCreation", [C, M]> {}
const Pending = defineProof("PendingMeshCreation");
interface Evidence {
  readonly tenantId: TenantId;
  readonly cidr: string;
  readonly record: MeshCreationRecord;
  readonly active: Effect.Effect<void, UpstreamError>;
  readonly context: (digest: string) => Effect.Effect<void, UpstreamError>;
  readonly beginSend: () => Effect.Effect<string, UpstreamError>;
  readonly rejected: (token: string) => Effect.Effect<void, UpstreamError>;
}
const evidence = new WeakMap<object, Evidence>();
export const pendingMeshCreationEvidenceOf = <C, M>(proof: PendingMeshCreation<C, M>): Evidence => {
  const found = evidence.get(proof);
  if (!found) throw new Error("PendingMeshCreation proof was not minted by src/proofs");
  return found;
};

export const pendingMeshCreation = <C, M>(caller: Named<C, Principal>, mesh: Named<M, MeshId>, key: string, holder: string) => Effect.gen(function* () {
  const p = caller.value, limits = yield* TenantLimits;
  if (p.resourceAllowlist !== null && !p.resourceAllowlist.has(mesh.value)) return null;
  if (p.actor.kind === "session" && ! (yield* (yield* TeamAdmin).isAdmin(p.tenantId, p.actor.userId))) return null;
  const found = yield* limits.meshCreation(p.tenantId, { op: "get", key });
  const reservation = yield* limits.meshCreation(p.tenantId, { op: "reservation", key, meshId: mesh.value });
  const cidr = yield* (yield* MeshStore).cidrOf(p.tenantId, mesh.value);
  if (found.state !== "record" || found.record.phase !== "creating" || found.record.meshId !== mesh.value || found.record.holder !== holder || reservation.state !== "reservation" || Option.isNone(cidr)) return null;
  const labels = found.record.labels ?? { [MESH_CREATION_LABEL]: key };
  if (labels[MESH_CREATION_LABEL] !== key || !carriesRequiredLabels(p, labels)) return null;
  let record = found.record;
  const fail = () => new UpstreamError({ operation: "meshCreationIntent", status: null });
  const write = (command: MeshCreationCommand) => limits.meshCreation(p.tenantId, command).pipe(
    Effect.mapError(fail), Effect.flatMap((result) => {
      if (result.state !== "record") return Effect.fail(fail());
      record = result.record;
      return Effect.void;
    }),
  );
  const proof: PendingMeshCreation<C, M> = Object.freeze({ ...Pending.prove(caller, mesh) });
  evidence.set(proof, Object.freeze({
    tenantId: p.tenantId, cidr: cidr.value, get record() { return record; },
    active: limits.meshCreation(p.tenantId, { op: "active", key, meshId: mesh.value, holder }).pipe(
      Effect.mapError(fail), Effect.flatMap((result) => result.state === "ok" ? Effect.void : Effect.fail(fail())),
    ),
    context: (context: string) => write({ op: "context", key, meshId: mesh.value, holder, context }),
    beginSend: () => Effect.gen(function* () {
      const token = crypto.randomUUID();
      yield* write({ op: "send", key, meshId: mesh.value, holder, token });
      return token;
    }),
    rejected: (token: string) => write({ op: "reject", key, meshId: mesh.value, token }),
  }));
  return proof;
});
