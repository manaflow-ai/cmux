/** Trusted: operation-specific authority never grants access to unrelated snapshots. */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import { SnapshotStore } from "../db/snapshots.ts";
import { actorRef, carriesRequiredLabels, type Principal } from "../domain/principal.ts";
import { snapshotNotFound, unavailable } from "../errors.ts";
import type { SnapshotId } from "../lib/ids.ts";
import { TenantLimits } from "../limits/service.ts";
import type { SnapshotCapture } from "../limits/snapshot-capture.ts";

export interface AuthorizedSnapshotCapture<C, S> extends Proof<"AuthorizedSnapshotCapture", [C, S]> {}
const Authorized = defineProof("AuthorizedSnapshotCapture");
const evidence = new WeakMap<object, SnapshotCapture>();
export const snapshotCaptureEvidenceOf = <C, S>(proof: AuthorizedSnapshotCapture<C, S>): SnapshotCapture => {
  const record = evidence.get(proof);
  if (record === undefined) throw new Error("snapshot capture proof was not minted by src/proofs");
  return record;
};
export const authorizedSnapshotCapture = <C, S>(caller: Named<C, Principal>, snapshot: Named<S, SnapshotId>) => Effect.gen(function* () {
  const result = yield* (yield* TenantLimits).snapshotCapture(caller.value.tenantId, { op: "get", id: snapshot.value }).pipe(Effect.mapError(() => unavailable()));
  if (result.state !== "record" || result.record.intent.id !== snapshot.value) return yield* Effect.fail(snapshotNotFound());
  const { record } = result, p = caller.value;
  const originalActor = actorRef(p.actor) === record.intent.createdBy;
  const selected = p.resourceAllowlist === null || p.resourceAllowlist.has(snapshot.value)
    || (originalActor && p.resourceAllowlist.has(record.intent.sourceVmId));
  if (!selected || !carriesRequiredLabels(p, record.intent.labels) || (p.actor.kind === "service" && !originalActor)) return yield* Effect.fail(snapshotNotFound());
  const row = yield* (yield* SnapshotStore).inspect(p.tenantId, snapshot.value).pipe(Effect.mapError(() => unavailable()));
  if (Option.isSome(row) && (!carriesRequiredLabels(p, row.value.labels) || row.value.createdBy !== record.intent.createdBy)) return yield* Effect.fail(snapshotNotFound());
  const proof: AuthorizedSnapshotCapture<C, S> = Object.freeze({ ...Authorized.prove(caller, snapshot) });
  evidence.set(proof, record);
  return proof;
});
